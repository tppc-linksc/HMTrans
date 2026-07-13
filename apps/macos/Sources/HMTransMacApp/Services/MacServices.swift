import AppKit
import Darwin
import Foundation
import Network
import HMTransCore

enum TrustedDevicesStore {
    // v0.1 的信任可能只经过单边弹窗，不能迁移为 v0.2 的双端配对关系。
    private static let key = "trustedDeviceIds.v3.deviceSnapshot"
    private static let fingerprintKey = "trustedDeviceFingerprints.v1"

    static func contains(_ deviceId: String?) -> Bool {
        guard let deviceId, !deviceId.isEmpty else { return false }
        return Set(UserDefaults.standard.stringArray(forKey: key) ?? []).contains(deviceId)
    }

    static func insert(_ deviceId: String?) {
        guard let deviceId, !deviceId.isEmpty else { return }
        var ids = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        ids.insert(deviceId)
        UserDefaults.standard.set(Array(ids).sorted(), forKey: key)
    }

    static func insert(_ deviceId: String?, fingerprint: String?) {
        insert(deviceId)
        guard let deviceId, let fingerprint, !fingerprint.isEmpty else { return }
        var values = UserDefaults.standard.dictionary(forKey: fingerprintKey) as? [String: String] ?? [:]
        values[deviceId] = fingerprint
        UserDefaults.standard.set(values, forKey: fingerprintKey)
    }

    static func matches(_ deviceId: String?, fingerprint: String?) -> Bool {
        guard contains(deviceId), let deviceId, let fingerprint, !fingerprint.isEmpty else { return false }
        let values = UserDefaults.standard.dictionary(forKey: fingerprintKey) as? [String: String] ?? [:]
        return values[deviceId] == fingerprint
    }

    static func remove(_ deviceId: String?) {
        guard let deviceId, !deviceId.isEmpty else { return }
        var ids = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        ids.remove(deviceId)
        UserDefaults.standard.set(Array(ids).sorted(), forKey: key)
        var values = UserDefaults.standard.dictionary(forKey: fingerprintKey) as? [String: String] ?? [:]
        values.removeValue(forKey: deviceId)
        UserDefaults.standard.set(values, forKey: fingerprintKey)
    }
}

func confirmIncomingFile(_ meta: FileMeta) -> Bool {
    TrustedDevicesStore.matches(meta.senderDeviceId, fingerprint: meta.senderFingerprint)
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
