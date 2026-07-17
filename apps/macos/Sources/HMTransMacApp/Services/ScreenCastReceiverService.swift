@preconcurrency import Network
import Foundation
import HMTransCore
import OSLog

private let screenCastLogger = Logger(subsystem: "com.linksc.hmtrans.mac", category: "ScreenCast")

/// 独立于文件传输端口的投屏接收器。监听器只管理会话注册；每条已接收连接
/// 使用自己的串行队列解析、验序和解密，避免一台 Pad 的高码率流阻塞另一台。
final class ScreenCastReceiverService: @unchecked Sendable {
    static let maximumConcurrentStreams = ScreenCastAdmissionPolicy.maximumConcurrentStreams
    private static let maximumPendingHandshakes = 8

    fileprivate enum AuthorizationResult {
        case accepted(String)
        case rejected(String)
    }

    struct Callbacks: Sendable {
        let onListening: @Sendable (UInt16) -> Void
        let onConnected: @Sendable (String, ScreenCastHello) -> Void
        let onVideoConfig: @Sendable (String, ScreenCastVideoConfig) -> Void
        let onVideoFrame: @Sendable (String, Data, UInt64, Bool, Bool) -> Void
        let onDisconnected: @Sendable (String, String) -> Void
        let onNetworkTestCompleted: @Sendable (ScreenCastNetworkTestResult) -> Void
        let onFailure: @Sendable (String) -> Void
    }

    private let queue = DispatchQueue(label: "HMTrans.ScreenCastReceiver.Registry", qos: .userInitiated)
    private var listener: NWListener?
    /// 未完成 HELLO 鉴权的连接也必须由服务持有；否则 newConnectionHandler 返回后
    /// 会话立即释放，Network.framework 虽已接受 TCP，却永远不会注册 receive 回调。
    private var sessions: [ObjectIdentifier: ScreenCastReceiverSession] = [:]
    private var activeSessions: [String: (session: ScreenCastReceiverSession, hello: ScreenCastHello)] = [:]
    private var activeNetworkTest: ScreenCastReceiverSession?
    private var callbacks: Callbacks?

    func start(port: UInt16, callbacks: Callbacks) throws {
        guard port > 0, let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw HMTransError.usage("投屏端口必须是 1 到 65535 之间的整数")
        }
        let listener = try NWListener(using: .tcp, on: endpointPort)
        queue.sync {
            self.listener?.cancel()
            let existingSessions = Array(self.sessions.values)
            self.sessions.removeAll()
            self.activeSessions.removeAll()
            self.activeNetworkTest = nil
            existingSessions.forEach { $0.requestClose(reason: "投屏服务正在重启", notifyPeer: true) }
            self.listener = listener
            self.callbacks = callbacks

            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, self.listener === listener else { return }
                switch state {
                case .ready:
                    callbacks.onListening(port)
                case let .failed(error):
                    callbacks.onFailure("投屏服务启动失败：\(error.localizedDescription)")
                case .cancelled:
                    break
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else {
                    connection.cancel()
                    return
                }
                guard self.sessions.count < Self.maximumConcurrentStreams + Self.maximumPendingHandshakes else {
                    screenCastLogger.warning("拒绝投屏连接：未鉴权连接数量已达上限")
                    connection.cancel()
                    return
                }
                let session = ScreenCastReceiverSession(connection: connection, owner: self)
                self.sessions[ObjectIdentifier(session)] = session
                session.start()
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            listener?.cancel()
            listener = nil
            let existingSessions = Array(sessions.values)
            sessions.removeAll()
            activeSessions.removeAll()
            activeNetworkTest = nil
            existingSessions.forEach { $0.requestClose(reason: "Mac 已停止投屏服务", notifyPeer: true) }
        }
    }

    func stopStream(sessionID: String, reason: String = "Mac 已停止投屏") {
        queue.async { [weak self] in
            self?.activeSessions[sessionID]?.session.requestClose(reason: reason, notifyPeer: true)
        }
    }

    func stopAllStreams(reason: String = "Mac 已停止全部投屏") {
        queue.async { [weak self] in
            self?.activeSessions.values.forEach { $0.session.requestClose(reason: reason, notifyPeer: true) }
        }
    }

    private func authorize(_ hello: ScreenCastHello) -> AuthorizationResult {
        guard hello.app == "HMTrans",
              hello.protocol == screenCastProtocolVersion,
              hello.codec == "h264-annexb" else {
            return .rejected("投屏协议或编码格式不兼容")
        }
        guard !hello.deviceId.isEmpty,
              !hello.identityFingerprint.isEmpty,
              !hello.sessionId.isEmpty,
              (1...4096).contains(hello.width),
              (1...4096).contains(hello.height),
              (1...60).contains(hello.frameRate) else {
            return .rejected("投屏参数无效")
        }
        guard TrustedDevicesStore.matches(hello.deviceId, fingerprint: hello.identityFingerprint) else {
            return .rejected("设备尚未配对或身份已经变化")
        }
        guard let secret = TrustedDevicesStore.sharedSecret(for: hello.deviceId), secret.count == 64 else {
            return .rejected("该配对来自旧版本，请删除设备后重新配对以启用投屏")
        }
        if let reason = ScreenCastAdmissionPolicy.rejectionReason(
            existing: activeSessions.values.map { $0.hello },
            candidate: hello
        ) {
            return .rejected(reason)
        }
        return .accepted(secret)
    }

    private func claim(_ session: ScreenCastReceiverSession, hello: ScreenCastHello) -> AuthorizationResult {
        switch authorize(hello) {
        case let .accepted(secret):
            activeSessions[hello.sessionId] = (session, hello)
            return .accepted(secret)
        case let .rejected(reason):
            return .rejected(reason)
        }
    }

    private func release(_ session: ScreenCastReceiverSession, reason: String) {
        sessions.removeValue(forKey: ObjectIdentifier(session))
        if let entry = activeSessions.first(where: { $0.value.session === session }) {
            activeSessions.removeValue(forKey: entry.key)
            callbacks?.onDisconnected(entry.key, reason)
        }
        if activeNetworkTest === session {
            activeNetworkTest = nil
        }
    }

    fileprivate func accept(_ session: ScreenCastReceiverSession, hello: ScreenCastHello) -> AuthorizationResult {
        queue.sync { claim(session, hello: hello) }
    }

    fileprivate func acceptNetworkTest(
        _ session: ScreenCastReceiverSession,
        hello: ScreenCastNetworkTestHello
    ) -> AuthorizationResult {
        queue.sync {
            guard hello.app == "HMTrans",
                  hello.protocol == screenCastProtocolVersion,
                  !hello.deviceId.isEmpty,
                  !hello.identityFingerprint.isEmpty,
                  !hello.sessionId.isEmpty,
                  (8 * 1_024 * 1_024...64 * 1_024 * 1_024).contains(hello.payloadBytes),
                  TrustedDevicesStore.matches(hello.deviceId, fingerprint: hello.identityFingerprint),
                  let secret = TrustedDevicesStore.sharedSecret(for: hello.deviceId), secret.count == 64 else {
                return .rejected("网络测试身份或参数无效")
            }
            guard activeSessions.isEmpty else {
                return .rejected("请先停止投屏再进行网络测试")
            }
            guard activeNetworkTest == nil else {
                return .rejected("另一项投屏网络测试正在进行")
            }
            activeNetworkTest = session
            return .accepted(secret)
        }
    }

    fileprivate func publishConfig(
        _ config: ScreenCastVideoConfig,
        sessionID: String,
        from session: ScreenCastReceiverSession
    ) {
        callbacks?.onVideoConfig(sessionID, config)
    }

    fileprivate func authenticated(_ hello: ScreenCastHello, from session: ScreenCastReceiverSession) {
        callbacks?.onConnected(hello.sessionId, hello)
    }

    fileprivate func publishFrame(
        _ data: Data,
        ptsUs: UInt64,
        keyFrame: Bool,
        codecConfig: Bool,
        sessionID: String,
        from session: ScreenCastReceiverSession
    ) {
        callbacks?.onVideoFrame(sessionID, data, ptsUs, keyFrame, codecConfig)
    }

    fileprivate func networkTestCompleted(_ result: ScreenCastNetworkTestResult) {
        callbacks?.onNetworkTestCompleted(result)
    }

    fileprivate func sessionClosed(_ session: ScreenCastReceiverSession, reason: String) {
        queue.async { [weak self] in self?.release(session, reason: reason) }
    }
}

private final class ScreenCastReceiverSession: @unchecked Sendable {
    private static let heartbeatTimeout: TimeInterval = 6
    private static let handshakeTimeout: TimeInterval = 10

    private let connection: NWConnection
    private weak var owner: ScreenCastReceiverService?
    private let queue: DispatchQueue
    private var parser = ScreenCastPacketParser()
    private var cipher: ScreenCastCipher?
    private var hello: ScreenCastHello?
    private var networkTestHello: ScreenCastNetworkTestHello?
    private var networkTestStartedAt: Date?
    private var networkTestReceivedBytes = 0
    private var networkTestServerResultSent = false
    private var lastHeartbeat = Date()
    private var lastHeartbeatSent = Date.distantPast
    private var handshakeTimer: DispatchSourceTimer?
    private var heartbeatTimer: DispatchSourceTimer?
    private var outgoingSequence: UInt64 = 1
    private var lastIncomingSequence: UInt64?
    private var didPublishAuthentication = false
    private var closed = false

    init(connection: NWConnection, owner: ScreenCastReceiverService) {
        self.connection = connection
        self.owner = owner
        self.queue = DispatchQueue(
            label: "HMTrans.ScreenCastReceiver.Session.\(UUID().uuidString)",
            qos: .userInitiated
        )
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                startHandshakeWatchdog()
                receiveNext()
            case let .failed(error):
                close(reason: "投屏连接失败：\(error.localizedDescription)", notifyPeer: false)
            case .cancelled:
                close(reason: "投屏连接已断开", notifyPeer: false)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func requestClose(reason: String, notifyPeer: Bool) {
        queue.async { [weak self] in self?.close(reason: reason, notifyPeer: notifyPeer) }
    }

    func close(reason: String, notifyPeer: Bool) {
        guard !closed else { return }
        closed = true
        screenCastLogger.info("关闭投屏连接：\(reason, privacy: .public)")
        handshakeTimer?.cancel()
        handshakeTimer = nil
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        owner?.sessionClosed(self, reason: reason)
        if notifyPeer, hello != nil,
           let packet = try? encryptedPacket(
               type: .streamControl,
               payload: encodeScreenCastJSON(ScreenCastStreamControl(command: "stop"))
           ) {
            // 先把停止命令交给内核发送，再取消连接，Pad 才能立即关闭系统录屏。
            connection.send(content: packet, completion: .contentProcessed { [self] _ in
                connection.cancel()
            })
            return
        }
        connection.cancel()
    }

    private func receiveNext() {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    for packet in try parser.append(data) {
                        try handle(packet)
                    }
                } catch {
                    screenCastLogger.error("解析投屏数据失败：\(error.localizedDescription, privacy: .public)")
                    close(reason: error.localizedDescription, notifyPeer: false)
                    return
                }
            }
            if let error {
                close(reason: "投屏连接中断：\(error.localizedDescription)", notifyPeer: false)
                return
            }
            if complete {
                close(reason: "MatePad 已停止投屏", notifyPeer: false)
                return
            }
            receiveNext()
        }
    }

    private func handle(_ packet: ScreenCastPacket) throws {
        if hello == nil, networkTestHello == nil {
            let validFirstPacket = (packet.header.type == .hello || packet.header.type == .networkTestHello)
                && !packet.header.flags.contains(.encrypted)
                && isNewIncomingSequence(packet.header.sequence)
            guard validFirstPacket else {
                screenCastLogger.error(
                    "首包无效：type=\(packet.header.type.rawValue) flags=\(packet.header.flags.rawValue) seq=\(packet.header.sequence) last=\(self.lastIncomingSequence ?? 0)"
                )
                throw ScreenCastProtocolError.invalidHeader
            }
            handshakeTimer?.cancel()
            handshakeTimer = nil
            lastIncomingSequence = packet.header.sequence
            if packet.header.type == .networkTestHello {
                let testHello = try decodeScreenCastJSON(ScreenCastNetworkTestHello.self, from: packet.payload)
                switch owner?.acceptNetworkTest(self, hello: testHello) {
                case let .accepted(secret):
                    do {
                        cipher = try ScreenCastCipher(sharedSecret: secret)
                        networkTestHello = testHello
                        send(try encryptedPacket(
                            type: .ack,
                            payload: encodeScreenCastJSON(
                                ScreenCastAck(accepted: true, sessionId: testHello.sessionId)
                            )
                        ))
                        lastHeartbeat = Date()
                        startHeartbeatWatchdog()
                    } catch {
                        owner?.sessionClosed(self, reason: error.localizedDescription)
                        throw error
                    }
                case let .rejected(reason):
                    try sendPlainAndClose(
                        type: .ack,
                        payload: encodeScreenCastJSON(
                            ScreenCastAck(accepted: false, sessionId: testHello.sessionId, reason: reason)
                        ),
                        reason: reason
                    )
                case .none:
                    close(reason: "投屏网络测试服务不可用", notifyPeer: false)
                }
                return
            }

            let castHello = try decodeScreenCastJSON(ScreenCastHello.self, from: packet.payload)
            switch owner?.accept(self, hello: castHello) {
            case let .accepted(secret):
                do {
                    cipher = try ScreenCastCipher(sharedSecret: secret)
                    self.hello = castHello
                    send(try encryptedPacket(
                        type: .ack,
                        payload: encodeScreenCastJSON(ScreenCastAck(accepted: true, sessionId: castHello.sessionId))
                    ))
                    lastHeartbeat = Date()
                    startHeartbeatWatchdog()
                } catch {
                    owner?.sessionClosed(self, reason: error.localizedDescription)
                    throw error
                }
            case let .rejected(reason):
                try sendPlainAndClose(
                        type: .ack,
                        payload: encodeScreenCastJSON(
                            ScreenCastAck(accepted: false, sessionId: castHello.sessionId, reason: reason)
                    ),
                    reason: reason
                )
            case .none:
                close(reason: "投屏服务不可用", notifyPeer: false)
            }
            return
        }

        let encrypted = packet.header.flags.contains(.encrypted)
        let freshSequence = isNewIncomingSequence(packet.header.sequence)
        guard encrypted, freshSequence, let cipher else {
            screenCastLogger.error(
                "鉴权后帧头无效：type=\(packet.header.type.rawValue) flags=\(packet.header.flags.rawValue) seq=\(packet.header.sequence) last=\(self.lastIncomingSequence ?? 0) encrypted=\(encrypted) fresh=\(freshSequence) hasCipher=\(self.cipher != nil)"
            )
            throw ScreenCastProtocolError.invalidHeader
        }
        lastIncomingSequence = packet.header.sequence
        let payload = try cipher.decrypt(packet.payload, authenticating: packet.headerData)
        lastHeartbeat = Date()
        if !didPublishAuthentication, let hello {
            didPublishAuthentication = true
            owner?.authenticated(hello, from: self)
        }
        switch packet.header.type {
        case .videoConfig:
            guard let hello else { throw ScreenCastProtocolError.invalidHeader }
            let config = try decodeScreenCastJSON(ScreenCastVideoConfig.self, from: payload)
            guard config.codec == "h264-annexb",
                  (1...4096).contains(config.width),
                  (1...4096).contains(config.height),
                  (1...60).contains(config.frameRate) else {
                screenCastLogger.error(
                    "视频参数无效：codec=\(config.codec, privacy: .public) size=\(config.width)x\(config.height) fps=\(config.frameRate)"
                )
                throw ScreenCastProtocolError.invalidHeader
            }
            owner?.publishConfig(config, sessionID: hello.sessionId, from: self)
        case .videoFrame:
            guard let hello else { throw ScreenCastProtocolError.invalidHeader }
            owner?.publishFrame(
                payload,
                ptsUs: packet.header.presentationTimeUs,
                keyFrame: packet.header.flags.contains(.keyFrame),
                codecConfig: packet.header.flags.contains(.codecConfig),
                sessionID: hello.sessionId,
                from: self
            )
        case .networkTestPing:
            guard networkTestHello != nil else { throw ScreenCastProtocolError.invalidHeader }
            send(try encryptedPacket(type: .networkTestPong, payload: payload))
        case .networkTestData:
            guard let testHello = networkTestHello,
                  !networkTestServerResultSent else {
                throw ScreenCastProtocolError.invalidHeader
            }
            if networkTestStartedAt == nil { networkTestStartedAt = Date() }
            networkTestReceivedBytes += payload.count
            guard networkTestReceivedBytes <= testHello.payloadBytes else {
                throw ScreenCastProtocolError.payloadTooLarge
            }
            if networkTestReceivedBytes == testHello.payloadBytes {
                let elapsed = max(0.001, Date().timeIntervalSince(networkTestStartedAt ?? Date()))
                let throughput = Double(networkTestReceivedBytes * 8) / elapsed / 1_000_000
                let result = ScreenCastNetworkTestResult(
                    sessionId: testHello.sessionId,
                    receivedBytes: networkTestReceivedBytes,
                    durationMs: max(1, Int((elapsed * 1_000).rounded())),
                    throughputMbps: throughput,
                    averageRttMs: 0,
                    jitterMs: 0,
                    recommendation: Self.recommendation(for: throughput)
                )
                networkTestServerResultSent = true
                send(try encryptedPacket(type: .networkTestResult, payload: encodeScreenCastJSON(result)))
            }
        case .networkTestResult:
            guard let testHello = networkTestHello, networkTestServerResultSent else {
                throw ScreenCastProtocolError.invalidHeader
            }
            let result = try decodeScreenCastJSON(ScreenCastNetworkTestResult.self, from: payload)
            guard result.sessionId == testHello.sessionId,
                  result.receivedBytes == testHello.payloadBytes else {
                throw ScreenCastProtocolError.invalidHeader
            }
            owner?.networkTestCompleted(result)
            close(reason: "投屏网络测试完成", notifyPeer: false)
        case .networkTestPong:
            throw ScreenCastProtocolError.invalidHeader
        case .heartbeat:
            break
        case .end:
            let end = try? decodeScreenCastJSON(ScreenCastEnd.self, from: payload)
            close(reason: end?.reason ?? "MatePad 已停止投屏", notifyPeer: false)
        case .error:
            close(reason: String(data: payload, encoding: .utf8) ?? "MatePad 投屏异常", notifyPeer: false)
        case .hello, .ack, .streamControl, .networkTestHello:
            screenCastLogger.error("鉴权后收到不允许的消息：type=\(packet.header.type.rawValue)")
            throw ScreenCastProtocolError.invalidHeader
        }
    }

    private static func recommendation(for throughputMbps: Double) -> String {
        if throughputMbps >= 120 { return "双路 1080P60；单路可尝试 2K60" }
        if throughputMbps >= 80 { return "双路 1080P60" }
        if throughputMbps >= 50 { return "双路 1080P30" }
        if throughputMbps >= 25 { return "单路 1080P30" }
        return "720P30；建议改善 Wi-Fi 信号"
    }

    private func isNewIncomingSequence(_ sequence: UInt64) -> Bool {
        guard let lastIncomingSequence else { return true }
        return sequence > lastIncomingSequence
    }

    private func startHandshakeWatchdog() {
        handshakeTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.handshakeTimeout)
        timer.setEventHandler { [weak self] in
            guard let self, !closed, hello == nil, networkTestHello == nil else { return }
            close(reason: "投屏握手超时", notifyPeer: false)
        }
        handshakeTimer = timer
        timer.resume()
    }

    private func startHeartbeatWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, !closed else { return }
            if Date().timeIntervalSince(lastHeartbeat) > Self.heartbeatTimeout {
                close(reason: "MatePad 投屏心跳超时", notifyPeer: false)
                return
            }
            if Date().timeIntervalSince(lastHeartbeatSent) >= 2,
               let packet = try? encryptedPacket(
                   type: .heartbeat,
                   payload: encodeScreenCastJSON(["at": Int(Date().timeIntervalSince1970 * 1_000)])
               ) {
                lastHeartbeatSent = Date()
                send(packet)
            }
        }
        heartbeatTimer = timer
        timer.resume()
    }

    /// 拒绝原因必须先完整写入 TCP，再关闭会话；否则发送端只会看到“连接被重置”。
    private func sendPlainAndClose(type: ScreenCastMessageType, payload: Data, reason: String) throws {
        let header = ScreenCastHeader(
            type: type,
            flags: [],
            payloadLength: payload.count,
            sequence: outgoingSequence,
            presentationTimeUs: 0
        )
        outgoingSequence += 1
        let packet = try header.encoded() + payload
        connection.send(content: packet, completion: .contentProcessed { [weak self] _ in
            self?.close(reason: reason, notifyPeer: false)
        })
    }

    private func encryptedPacket(type: ScreenCastMessageType, payload: Data) throws -> Data {
        guard let cipher else { throw ScreenCastProtocolError.invalidSecret }
        let header = ScreenCastHeader(
            type: type,
            flags: [.encrypted],
            payloadLength: payload.count + 28,
            sequence: outgoingSequence,
            presentationTimeUs: 0
        )
        outgoingSequence += 1
        let headerData = try header.encoded()
        return headerData + (try cipher.encrypt(payload, authenticating: headerData))
    }

    private func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.close(reason: "发送投屏控制消息失败：\(error.localizedDescription)", notifyPeer: false)
            }
        })
    }
}
