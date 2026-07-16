@preconcurrency import Network
import Foundation
import HMTransCore

/// 独立于文件传输端口的投屏接收器。所有 Network.framework 回调都串行运行，
/// 从而保证同一时刻最多只有一台 MatePad 占用 Mac 的解码窗口。
final class ScreenCastReceiverService: @unchecked Sendable {
    fileprivate enum AuthorizationResult {
        case accepted(String)
        case rejected(String)
    }

    struct Callbacks: Sendable {
        let onListening: @Sendable (UInt16) -> Void
        let onConnected: @Sendable (ScreenCastHello) -> Void
        let onVideoConfig: @Sendable (ScreenCastVideoConfig) -> Void
        let onVideoFrame: @Sendable (Data, UInt64, Bool, Bool) -> Void
        let onDisconnected: @Sendable (String) -> Void
        let onFailure: @Sendable (String) -> Void
    }

    private let queue = DispatchQueue(label: "HMTrans.ScreenCastReceiver", qos: .userInitiated)
    private var listener: NWListener?
    private var activeSession: ScreenCastReceiverSession?
    private var callbacks: Callbacks?

    func start(port: UInt16, callbacks: Callbacks) throws {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        queue.sync {
            self.listener?.cancel()
            self.activeSession?.close(reason: "投屏服务正在重启", notifyPeer: true)
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
                let session = ScreenCastReceiverSession(connection: connection, owner: self, queue: self.queue)
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
            activeSession?.close(reason: "Mac 已停止投屏服务", notifyPeer: true)
            activeSession = nil
        }
    }

    func stopActiveStream(reason: String = "Mac 已停止投屏") {
        queue.async { [weak self] in
            self?.activeSession?.close(reason: reason, notifyPeer: true)
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
        guard activeSession == nil else {
            return .rejected("Mac 正在接收另一台设备的投屏")
        }
        return .accepted(secret)
    }

    private func claim(_ session: ScreenCastReceiverSession, hello: ScreenCastHello) -> AuthorizationResult {
        switch authorize(hello) {
        case let .accepted(secret):
            activeSession = session
            return .accepted(secret)
        case let .rejected(reason):
            return .rejected(reason)
        }
    }

    private func release(_ session: ScreenCastReceiverSession, reason: String) {
        guard activeSession === session else { return }
        activeSession = nil
        callbacks?.onDisconnected(reason)
    }

    fileprivate func accept(_ session: ScreenCastReceiverSession, hello: ScreenCastHello) -> AuthorizationResult {
        claim(session, hello: hello)
    }

    fileprivate func publishConfig(_ config: ScreenCastVideoConfig, from session: ScreenCastReceiverSession) {
        guard activeSession === session else { return }
        callbacks?.onVideoConfig(config)
    }

    fileprivate func authenticated(_ hello: ScreenCastHello, from session: ScreenCastReceiverSession) {
        guard activeSession === session else { return }
        callbacks?.onConnected(hello)
    }

    fileprivate func publishFrame(
        _ data: Data,
        ptsUs: UInt64,
        keyFrame: Bool,
        codecConfig: Bool,
        from session: ScreenCastReceiverSession
    ) {
        guard activeSession === session else { return }
        callbacks?.onVideoFrame(data, ptsUs, keyFrame, codecConfig)
    }

    fileprivate func sessionClosed(_ session: ScreenCastReceiverSession, reason: String) {
        release(session, reason: reason)
    }
}

private final class ScreenCastReceiverSession: @unchecked Sendable {
    private static let heartbeatTimeout: TimeInterval = 6

    private let connection: NWConnection
    private weak var owner: ScreenCastReceiverService?
    private let queue: DispatchQueue
    private var parser = ScreenCastPacketParser()
    private var cipher: ScreenCastCipher?
    private var hello: ScreenCastHello?
    private var lastHeartbeat = Date()
    private var lastHeartbeatSent = Date.distantPast
    private var heartbeatTimer: DispatchSourceTimer?
    private var outgoingSequence: UInt64 = 1
    private var lastIncomingSequence: UInt64?
    private var didPublishAuthentication = false
    private var closed = false

    init(connection: NWConnection, owner: ScreenCastReceiverService, queue: DispatchQueue) {
        self.connection = connection
        self.owner = owner
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
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

    func close(reason: String, notifyPeer: Bool) {
        guard !closed else { return }
        closed = true
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        owner?.sessionClosed(self, reason: reason)
        if notifyPeer,
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
        if hello == nil {
            guard packet.header.type == .hello,
                  !packet.header.flags.contains(.encrypted),
                  isNewIncomingSequence(packet.header.sequence) else {
                throw ScreenCastProtocolError.invalidHeader
            }
            lastIncomingSequence = packet.header.sequence
            let hello = try decodeScreenCastJSON(ScreenCastHello.self, from: packet.payload)
            switch owner?.accept(self, hello: hello) {
            case let .accepted(secret):
                do {
                    cipher = try ScreenCastCipher(sharedSecret: secret)
                    self.hello = hello
                    send(try encryptedPacket(
                        type: .ack,
                        payload: encodeScreenCastJSON(ScreenCastAck(accepted: true, sessionId: hello.sessionId))
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
                        ScreenCastAck(accepted: false, sessionId: hello.sessionId, reason: reason)
                    ),
                    reason: reason
                )
            case .none:
                close(reason: "投屏服务不可用", notifyPeer: false)
            }
            return
        }

        guard packet.header.flags.contains(.encrypted),
              isNewIncomingSequence(packet.header.sequence),
              let cipher else {
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
            let config = try decodeScreenCastJSON(ScreenCastVideoConfig.self, from: payload)
            guard config.codec == "h264-annexb",
                  (1...4096).contains(config.width),
                  (1...4096).contains(config.height),
                  (1...60).contains(config.frameRate) else {
                throw ScreenCastProtocolError.invalidHeader
            }
            owner?.publishConfig(config, from: self)
        case .videoFrame:
            owner?.publishFrame(
                payload,
                ptsUs: packet.header.presentationTimeUs,
                keyFrame: packet.header.flags.contains(.keyFrame),
                codecConfig: packet.header.flags.contains(.codecConfig),
                from: self
            )
        case .heartbeat:
            break
        case .end:
            let end = try? decodeScreenCastJSON(ScreenCastEnd.self, from: payload)
            close(reason: end?.reason ?? "MatePad 已停止投屏", notifyPeer: false)
        case .error:
            close(reason: String(data: payload, encoding: .utf8) ?? "MatePad 投屏异常", notifyPeer: false)
        case .hello, .ack, .streamControl:
            throw ScreenCastProtocolError.invalidHeader
        }
    }

    private func isNewIncomingSequence(_ sequence: UInt64) -> Bool {
        guard let lastIncomingSequence else { return true }
        return sequence > lastIncomingSequence
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
