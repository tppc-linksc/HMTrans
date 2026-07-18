import AppKit
import Darwin
import Foundation
import Network
import HMTransCore

enum TrustedDevicesStore {
    static func contains(_ deviceId: String?) -> Bool {
        PairingConfigurationStore.contains(deviceId)
    }

    static func insert(
        _ deviceId: String?, fingerprint: String?, sharedSecret: String? = nil,
        securityVersion: Int = hmTransSecurityVersion
    ) {
        PairingConfigurationStore.insert(
            deviceId,
            fingerprint: fingerprint,
            sharedSecret: sharedSecret,
            securityVersion: securityVersion
        )
    }

    static func sharedSecret(for deviceId: String?) -> String? {
        PairingConfigurationStore.sharedSecret(for: deviceId)
    }

    static func matches(_ deviceId: String?, fingerprint: String?) -> Bool {
        PairingConfigurationStore.matches(deviceId, fingerprint: fingerprint)
    }

    static func remove(_ deviceId: String?) {
        PairingConfigurationStore.remove(deviceId)
    }
}

/// 把 1 MB 网络分块产生的高频进度事件收敛到每任务约 10 Hz；首帧和完成帧始终上报。
final class TransferProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastUpdates: [String: TimeInterval] = [:]
    private let interval: TimeInterval

    init(interval: TimeInterval = 0.1) {
        self.interval = interval
    }

    func shouldPublish(id: String, current: Int64, total: Int64) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        if current == 0 || current >= total {
            lastUpdates.removeValue(forKey: id)
            return true
        }
        if let last = lastUpdates[id], now - last < interval { return false }
        lastUpdates[id] = now
        return true
    }
}

/// 文件元数据签名允许短时间时钟偏差，但同一个认证 ID 只能使用一次，阻止局域网抓包后重放接收提示。
private final class FileMetadataReplayGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String: TimeInterval] = [:]
    private let retention: TimeInterval = 5 * 60
    private let maximumEntries = 2_048

    func accept(_ meta: FileMeta) -> Bool {
        guard let id = meta.authenticationId, !id.isEmpty else { return false }
        let now = Date().timeIntervalSince1970
        return lock.withLock {
            seen = seen.filter { now - $0.value <= retention }
            guard seen[id] == nil else { return false }
            if seen.count >= maximumEntries, let oldest = seen.min(by: { $0.value < $1.value })?.key {
                seen.removeValue(forKey: oldest)
            }
            seen[id] = now
            return true
        }
    }
}

private let fileMetadataReplayGuard = FileMetadataReplayGuard()

func confirmIncomingFile(_ meta: FileMeta) -> Bool {
    guard TrustedDevicesStore.matches(meta.senderDeviceId, fingerprint: meta.senderFingerprint),
          let sharedSecret = TrustedDevicesStore.sharedSecret(for: meta.senderDeviceId)
    else { return false }
    return verifyFileMetaAuthentication(meta, sharedSecret: sharedSecret)
        && fileMetadataReplayGuard.accept(meta)
}

@MainActor
func promptForIncomingFile(_ meta: FileMeta) -> Bool {
    let alert = NSAlert()
    alert.messageText = "接收来自 \(meta.senderName ?? meta.senderPlatform ?? "已配对设备") 的文件？"
    alert.informativeText = "\(meta.fileName)\n大小：\(ByteCountFormatter.string(fromByteCount: meta.fileSize, countStyle: .file))"
    alert.addButton(withTitle: "接收")
    alert.addButton(withTitle: "拒绝")
    return alert.runModal() == .alertFirstButtonReturn
}

@MainActor
func promptForPairingCode(device: DeviceInfo) -> String? {
    let alert = NSAlert()
    alert.messageText = "输入 \(device.deviceName) 的配对码"
    alert.informativeText = "请在对方设备上查看当前六位配对码。校验成功后双方才会保存信任关系。"
    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 28))
    input.placeholderString = "六位配对码"
    alert.accessoryView = input
    alert.addButton(withTitle: "配对并连接")
    alert.addButton(withTitle: "取消")
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let code = input.stringValue.filter(\.isNumber)
    guard code.count == 6 else {
        let error = NSAlert()
        error.messageText = "配对码格式错误"
        error.informativeText = "请输入对方设备显示的六位数字。"
        error.runModal()
        return nil
    }
    return code
}

@MainActor
func confirmForgetDevice(named deviceName: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = "移除 \(deviceName)？"
    alert.informativeText = "将删除双方保存的配对关系；下次连接需要重新输入六位配对码。传输历史不会被删除。"
    alert.addButton(withTitle: "移除设备")
    alert.addButton(withTitle: "取消")
    alert.alertStyle = .warning
    return alert.runModal() == .alertFirstButtonReturn
}

/// 在不形成 `DispatchQueue.main.sync` 循环的情况下，将 Core 的同步接收回调桥接到 AppKit。
/// 接收器停止时不会等待此工作队列，界面未在 `timeout` 内响应时按拒绝处理。
func evaluateOnMain<T: Sendable>(
    timeout: TimeInterval,
    fallback: T,
    operation: @escaping @MainActor @Sendable () -> T
) -> T {
    if Thread.isMainThread {
        return MainActor.assumeIsolated { operation() }
    }
    let semaphore = DispatchSemaphore(value: 0)
    let result = MainThreadResultBox<T>()
    DispatchQueue.main.async {
        guard result.beginIfActive() else { return }
        result.store(operation())
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + timeout) == .success else {
        result.cancel()
        return fallback
    }
    return result.value ?? fallback
}

private final class MainThreadResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: T?
    private var active = true

    var value: T? { lock.withLock { storedValue } }
    func beginIfActive() -> Bool {
        lock.withLock {
            guard active else { return false }
            active = false
            return true
        }
    }
    func cancel() { lock.withLock { active = false } }
    func store(_ value: T) { lock.withLock { storedValue = value } }
}

func fallbackScanCandidates(savedHost: String) -> [String] {
    let trimmed = savedHost.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !isLocalIPv4Address(trimmed) else { return [] }
    return [trimmed]
}

func localIPv4Addresses() -> [String] {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
    defer { freeifaddrs(interfaces) }

    var addresses: [String] = []
    var pointer: UnsafeMutablePointer<ifaddrs>? = first
    while let current = pointer {
        defer { pointer = current.pointee.ifa_next }
        let flags = Int32(current.pointee.ifa_flags)
        guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
        guard current.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }

        let name = String(cString: current.pointee.ifa_name)
        guard name.hasPrefix("en") else { continue }

        let address = current.pointee.ifa_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            ipv4String(from: $0.pointee)
        }
        addresses.append(address)
    }
    return addresses
}

func tcpPortIsOpen(host: String, port: UInt16, timeout: TimeInterval) -> Bool {
    guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
    let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
    let queue = DispatchQueue(label: "HMTrans.PortProbe", qos: .utility)
    let semaphore = DispatchSemaphore(value: 0)
    let box = ProbeBox()

    connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
            box.markReady()
            semaphore.signal()
        case .failed, .cancelled:
            semaphore.signal()
        default:
            break
        }
    }
    connection.start(queue: queue)
    let result = semaphore.wait(timeout: .now() + timeout)
    connection.cancel()
    return result == .success && box.isReady
}

/// 在 Network.framework 回调队列与调用线程之间保护探测结果。
/// 信号量只负责时序协调，不是 Swift 内存隔离原语，因此结果值仍由锁保护。
private final class ProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false

    var isReady: Bool {
        lock.withLock { ready }
    }

    func markReady() {
        lock.withLock { ready = true }
    }
}

func ipv4String(from address: sockaddr_in) -> String {
    var addr = address.sin_addr
    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN))
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

func fileTypeLabel(_ fileName: String) -> String {
    let ext = URL(fileURLWithPath: fileName).pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
    return ext.isEmpty ? "文件" : ext.uppercased()
}

func isLocalIPv4Address(_ host: String) -> Bool {
    let value = host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return false }
    if value == "localhost" || value == "127.0.0.1" || value == "0.0.0.0" {
        return true
    }
    return Set(localIPv4Addresses()).contains(value)
}
