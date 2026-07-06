import AppKit
import Darwin
import Foundation
import Network
import PureSendCore

enum TrustedDevicesStore {
    private static let key = "trustedDeviceIds"

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

    static func remove(_ deviceId: String?) {
        guard let deviceId, !deviceId.isEmpty else { return }
        var ids = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        ids.remove(deviceId)
        UserDefaults.standard.set(Array(ids).sorted(), forKey: key)
    }
}

func confirmIncomingFile(_ meta: FileMeta) -> Bool {
    if TrustedDevicesStore.contains(meta.senderDeviceId) {
        return true
    }

    if Thread.isMainThread {
        return MainActor.assumeIsolated {
            runIncomingFileAlert(meta)
        }
    }
    return DispatchQueue.main.sync {
        MainActor.assumeIsolated {
            runIncomingFileAlert(meta)
        }
    }
}

@MainActor
private func runIncomingFileAlert(_ meta: FileMeta) -> Bool {
    let sender = meta.senderName ?? meta.senderPlatform ?? "未知设备"
    let alert = NSAlert()
    alert.messageText = "接收来自 \(sender) 的文件？"
    alert.informativeText = "\(meta.fileName)\n大小：\(formatBytes(meta.fileSize))\n首次确认后会信任此设备，后续自动接收。"
    alert.addButton(withTitle: "信任并接收")
    alert.addButton(withTitle: "拒绝")
    let accepted = alert.runModal() == .alertFirstButtonReturn
    if accepted {
        TrustedDevicesStore.insert(meta.senderDeviceId)
    }
    return accepted
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
    let queue = DispatchQueue(label: "PureSend.PortProbe", qos: .utility)
    let semaphore = DispatchSemaphore(value: 0)
    final class ProbeBox: @unchecked Sendable { var ready = false }
    let box = ProbeBox()

    connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
            box.ready = true
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
    return result == .success && box.ready
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
