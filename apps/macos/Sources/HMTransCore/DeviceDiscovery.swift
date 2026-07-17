import Darwin
import Foundation
import OSLog

private let discoveryLog = Logger(subsystem: "com.linksc.hmtrans", category: "discovery")

public struct DeviceInfo: Codable, Hashable, Identifiable, Sendable {
    public var id: String { deviceId }
    public let app: String
    public let version: String
    public let deviceName: String
    public let platform: String
    public let ip: String
    public let port: UInt16
    public let deviceId: String
    public let systemVersion: String?
    public let networkName: String?
    public let identityFingerprint: String?
    public let acknowledgedDeviceId: String?
    public let screenCastPort: UInt16?
    public let screenCastProtocolVersion: String?
    public let screenCastCapabilities: [String]?

    public init(
        app: String = "HMTrans",
        version: String = hmTransProtocolVersion,
        deviceName: String,
        platform: String,
        ip: String,
        port: UInt16 = defaultPort,
        deviceId: String,
        systemVersion: String? = nil,
        networkName: String? = nil,
        identityFingerprint: String? = nil,
        acknowledgedDeviceId: String? = nil,
        screenCastPort: UInt16? = nil,
        screenCastProtocolVersion: String? = nil,
        screenCastCapabilities: [String]? = nil
    ) {
        self.app = app
        self.version = version
        self.deviceName = deviceName
        self.platform = platform
        self.ip = ip
        self.port = port
        self.deviceId = deviceId
        self.systemVersion = systemVersion
        self.networkName = networkName
        self.identityFingerprint = identityFingerprint
        self.acknowledgedDeviceId = acknowledgedDeviceId
        self.screenCastPort = screenCastPort
        self.screenCastProtocolVersion = screenCastProtocolVersion
        self.screenCastCapabilities = screenCastCapabilities
    }
}

public final class DiscoveryService: @unchecked Sendable {
    private let listenQueue = DispatchQueue(label: "HMTrans.Discovery.Listen", qos: .utility)
    private let beaconQueue = DispatchQueue(label: "HMTrans.Discovery.Beacon", qos: .utility)
    private let lock = NSLock()
    private var socketFd: Int32 = -1
    private var running = false
    private var directedReplyAt: [String: Date] = [:]
    private let selfDeviceId: String
    private let deviceName: String
    private let platform: String
    private let transferPort: UInt16
    private let screenCastPort: UInt16
    private let discoveryPort: UInt16
    private let identityFingerprint: String
    private let shouldAcknowledge: @Sendable (DeviceInfo) -> Bool

    public init(
        deviceName: String = Host.current().localizedName ?? "Mac",
        platform: String = "macOS",
        transferPort: UInt16 = defaultPort,
        screenCastPort: UInt16 = defaultScreenCastPort,
        discoveryPort: UInt16 = 51_889,
        deviceId: String,
        identityFingerprint: String = "",
        shouldAcknowledge: @escaping @Sendable (DeviceInfo) -> Bool = { _ in true }
    ) {
        self.deviceName = deviceName
        self.platform = platform
        self.transferPort = transferPort
        self.screenCastPort = screenCastPort
        self.discoveryPort = discoveryPort
        self.selfDeviceId = deviceId
        self.identityFingerprint = identityFingerprint
        self.shouldAcknowledge = shouldAcknowledge
    }

    public func start(onDevice: @escaping @Sendable (DeviceInfo) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }

        let fd = try makeDiscoverySocket(port: discoveryPort)
        socketFd = fd
        running = true

        listenQueue.async { [weak self] in
            self?.listenLoop(fd: fd, onDevice: onDevice)
        }
        beaconQueue.async { [weak self] in
            self?.beaconLoop(fd: fd)
        }
    }

    public func stop() {
        lock.lock()
        let fd = socketFd
        socketFd = -1
        running = false
        lock.unlock()

        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
    }

    /// 向已保存地址发送带身份信息的发现信标。TCP 可达性无法证明身份，不能单独作为已连接依据。
    public func probe(address: String) {
        lock.lock()
        let fd = socketFd
        let canSend = running && fd >= 0
        lock.unlock()
        guard canSend, isUsableIPv4(address) else { return }
        let info = DeviceInfo(
            deviceName: deviceName,
            platform: platform,
            ip: primaryIPv4Address() ?? "0.0.0.0",
            port: transferPort,
            deviceId: selfDeviceId,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            identityFingerprint: identityFingerprint,
            screenCastPort: screenCastPort,
            screenCastProtocolVersion: screenCastProtocolVersion,
            screenCastCapabilities: ["receive-h264", "multi-cast-2", "network-test-v1"]
        )
        guard let data = try? JSONEncoder().encode(info) else { return }
        try? sendDatagram(fd: fd, data: data, address: address, port: discoveryPort)
    }

    private func isRunning(fd: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running && socketFd == fd
    }

    private func beaconLoop(fd: Int32) {
        while isRunning(fd: fd) {
            do {
                let info = DeviceInfo(
                    deviceName: deviceName,
                    platform: platform,
                    ip: primaryIPv4Address() ?? "0.0.0.0",
                    port: transferPort,
                    deviceId: selfDeviceId,
                    systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                    identityFingerprint: identityFingerprint,
                    screenCastPort: screenCastPort,
                    screenCastProtocolVersion: screenCastProtocolVersion,
                    screenCastCapabilities: ["receive-h264", "multi-cast-2", "network-test-v1"]
                )
                let data = try JSONEncoder().encode(info)
                try sendBroadcasts(fd: fd, data: data, port: discoveryPort)
            } catch {
                discoveryLog.error("Discovery beacon failed: \(String(describing: error), privacy: .public)")
            }
            waitBeforeNextBeacon(fd: fd)
        }
    }

    private func listenLoop(fd: Int32, onDevice: @escaping @Sendable (DeviceInfo) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 4096)

        while isRunning(fd: fd) {
            var remote = sockaddr_in()
            var remoteLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &remote) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                    recvfrom(fd, &buffer, buffer.count, 0, pointer, &remoteLen)
                }
            }
            if count <= 0 {
                if errno == EBADF || errno == EINVAL {
                    break
                }
                continue
            }

            do {
                var device = try JSONDecoder().decode(DeviceInfo.self, from: Data(buffer.prefix(count)))
                guard device.app == "HMTrans", device.deviceId != selfDeviceId else { continue }
                let remoteIP = addressString(from: remote)
                let peerIP = resolvedPeerIPv4(advertised: device.ip, remote: remoteIP)
                if device.ip != peerIP {
                    device = DeviceInfo(
                        deviceName: device.deviceName,
                        platform: device.platform,
                        ip: peerIP,
                        port: device.port,
                        deviceId: device.deviceId,
                        systemVersion: device.systemVersion,
                        networkName: device.networkName,
                        identityFingerprint: device.identityFingerprint,
                        acknowledgedDeviceId: device.acknowledgedDeviceId,
                        screenCastPort: device.screenCastPort,
                        screenCastProtocolVersion: device.screenCastProtocolVersion,
                        screenCastCapabilities: device.screenCastCapabilities
                    )
                }
                onDevice(device)
                // 广播只表示“附近可发现”；带确认 ID 的单播心跳只发给仍受信任的身份。
                // 因此解除配对通知丢失时，也不会让另一端长期保持虚假的已连接状态。
                if shouldAcknowledge(device) {
                    sendDirectedBeaconIfNeeded(fd: fd, deviceId: device.deviceId, address: peerIP)
                }
            } catch {
                discoveryLog.error("Discovery packet decode failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func sendDirectedBeaconIfNeeded(fd: Int32, deviceId: String, address: String) {
        let now = Date()
        if let last = directedReplyAt[deviceId], now.timeIntervalSince(last) < 2 {
            return
        }
        directedReplyAt[deviceId] = now
        let info = DeviceInfo(
            deviceName: deviceName,
            platform: platform,
            ip: primaryIPv4Address() ?? "0.0.0.0",
            port: transferPort,
            deviceId: selfDeviceId,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            identityFingerprint: identityFingerprint,
            acknowledgedDeviceId: deviceId,
            screenCastPort: screenCastPort,
            screenCastProtocolVersion: screenCastProtocolVersion,
            screenCastCapabilities: ["receive-h264", "multi-cast-2", "network-test-v1"]
        )
        guard let data = try? JSONEncoder().encode(info) else { return }
        do {
            try sendDatagram(fd: fd, data: data, address: address, port: discoveryPort)
        } catch {
            discoveryLog.error("Acknowledgement failed peer=\(deviceId, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}

private func makeDiscoverySocket(port: UInt16) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { throw HMTransError.system("UDP socket 失败：\(lastErrnoText())") }

    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)

    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard result == 0 else {
        close(fd)
        throw HMTransError.system("UDP 发现端口绑定失败：\(lastErrnoText())")
    }

    return fd
}

private func sendBroadcasts(fd: Int32, data: Data, port: UInt16) throws {
    var lastError: String?
    var sentAny = false

    for broadcast in broadcastAddresses() {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        inet_pton(AF_INET, broadcast, &address.sin_addr)

        let sent = data.withUnsafeBytes { rawBuffer in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, rawBuffer.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        if sent >= 0 {
            sentAny = true
        } else {
            lastError = lastErrnoText()
        }
    }

    guard sentAny else {
        throw HMTransError.system("UDP 广播失败：\(lastError ?? "unknown")")
    }
}

private func sendDatagram(fd: Int32, data: Data, address: String, port: UInt16) throws {
    var destination = sockaddr_in()
    destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    destination.sin_family = sa_family_t(AF_INET)
    destination.sin_port = port.bigEndian
    inet_pton(AF_INET, address, &destination.sin_addr)
    let sent = data.withUnsafeBytes { rawBuffer in
        withUnsafePointer(to: &destination) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, rawBuffer.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
    if sent < 0 {
        throw HMTransError.system("UDP 单播回应失败：\(lastErrnoText())")
    }
}

private struct IPv4Interface {
    let name: String
    let address: String
    let broadcast: String?
}

private func primaryIPv4Address() -> String? {
    preferredLANIPv4Interfaces().first?.address
}

private func broadcastAddresses() -> [String] {
    var addresses = Set(["255.255.255.255"])
    for interface in preferredLANIPv4Interfaces() {
        if let broadcast = interface.broadcast {
            addresses.insert(broadcast)
        }
    }
    return Array(addresses)
}

private func preferredLANIPv4Interfaces() -> [IPv4Interface] {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
    defer { freeifaddrs(interfaces) }

    var result: [IPv4Interface] = []
    var pointer: UnsafeMutablePointer<ifaddrs>? = first
    while let current = pointer {
        defer { pointer = current.pointee.ifa_next }
        let flags = Int32(current.pointee.ifa_flags)
        guard flags & IFF_UP != 0,
              flags & IFF_LOOPBACK == 0,
              current.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET)
        else { continue }

        let name = String(cString: current.pointee.ifa_name)
        guard isPreferredLANInterface(name) else { continue }

        let address = current.pointee.ifa_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            addressString(from: $0.pointee)
        }
        guard isUsableIPv4(address) else { continue }

        var broadcast: String?
        if flags & IFF_BROADCAST != 0,
           let broadaddr = current.pointee.ifa_dstaddr,
           broadaddr.pointee.sa_family == UInt8(AF_INET) {
            broadcast = broadaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                addressString(from: $0.pointee)
            }
        }

        result.append(IPv4Interface(name: name, address: address, broadcast: broadcast))
    }

    return result.sorted { left, right in
        let leftScore = interfaceScore(left)
        let rightScore = interfaceScore(right)
        if leftScore != rightScore {
            return leftScore < rightScore
        }
        return left.name < right.name
    }
}

private func isPreferredLANInterface(_ name: String) -> Bool {
    name.hasPrefix("en")
}

private func interfaceScore(_ interface: IPv4Interface) -> Int {
    var score = isPrivateIPv4(interface.address) ? 0 : 100
    if interface.name == "en0" {
        score -= 10
    }
    if interface.broadcast == nil {
        score += 20
    }
    return score
}

private func resolvedPeerIPv4(advertised: String, remote: String) -> String {
    // 优先使用 recvfrom 观察到的源地址。广播地址可能是有效但不可达的 VPN 或次要网卡地址；
    // 在多网卡 Mac 上向其回复会造成单边“已连接”状态。
    isUsableIPv4(remote) ? remote : advertised
}

private func isUsableIPv4(_ value: String) -> Bool {
    guard value != "0.0.0.0", value != "127.0.0.1", !value.isEmpty else { return false }
    var addr = in_addr()
    return inet_pton(AF_INET, value, &addr) == 1
}

private func isPrivateIPv4(_ value: String) -> Bool {
    let parts = value.split(separator: ".").compactMap { Int($0) }
    guard parts.count == 4 else { return false }
    if parts[0] == 10 { return true }
    if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
    if parts[0] == 192 && parts[1] == 168 { return true }
    return false
}

private func addressString(from address: sockaddr_in) -> String {
    var addr = address.sin_addr
    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN))
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

private func waitBeforeNextBeacon(fd: Int32) {
    guard fcntl(fd, F_GETFD) != -1 else { return }
    // 应用空闲时让内核挂起发现工作线程，避免反复唤醒 RunLoop 或进行短间隔休眠。
    var descriptor = pollfd(fd: fd, events: 0, revents: 0)
    _ = Darwin.poll(&descriptor, 1, 5_000)
}

private func lastErrnoText() -> String {
    String(cString: strerror(errno))
}
