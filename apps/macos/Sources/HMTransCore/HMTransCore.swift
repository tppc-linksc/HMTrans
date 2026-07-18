import CryptoKit
import Foundation
import Network
import OSLog

public let defaultPort: UInt16 = 51888
public let defaultChunkSize = 1_048_576
public let discoveryPort: UInt16 = 51889
public let hmTransProtocolVersion = "0.2.0"

private let coreLog = Logger(subsystem: "com.linksc.hmtrans", category: "transfer")

public func defaultReceiveDirectory() -> String {
    NSString(string: "~/Downloads/HMTrans").expandingTildeInPath
}

public func requestPairing(
    host: String,
    port: UInt16 = defaultPort,
    requesterDeviceId: String,
    requesterName: String,
    requesterPlatform: String,
    requesterSystemVersion: String,
    requesterIP: String,
    requesterPort: UInt16,
    code: String,
    requesterFingerprint: String,
    targetDeviceId: String,
    targetFingerprint: String,
    networkTimeout: TimeInterval = 30
) throws -> PairingOutcome {
    let initiator = try PairingInitiatorState(
        requesterDeviceId: requesterDeviceId,
        requesterName: requesterName,
        requesterPlatform: requesterPlatform,
        requesterSystemVersion: requesterSystemVersion,
        requesterIP: requesterIP,
        requesterPort: requesterPort,
        requesterFingerprint: requesterFingerprint,
        targetDeviceId: targetDeviceId,
        targetFingerprint: targetFingerprint,
        code: code
    )
    let connection = try BlockingNetworkConnection.connect(
        host: host,
        port: port,
        operationTimeout: networkTimeout
    )
    defer { connection.cancel() }
    try sendJSONLine(initiator.request, connection: connection)
    let challenge: PairingChallenge = try readJSONLine(connection: connection)
    let (confirmation, sharedSecret) = try initiator.answer(challenge)
    try sendJSONLine(confirmation, connection: connection)
    let response: PairingResponse = try readJSONLine(connection: connection)
    guard response.accepted, response.securityVersion == hmTransSecurityVersion else {
        return PairingOutcome(response: response, sharedSecret: nil)
    }
    return PairingOutcome(response: response, sharedSecret: sharedSecret)
}

/// 通知在线对端撤销配对。调用方应无论通知结果如何都立即清理本机信任。
public func requestUnpair(
    host: String,
    port: UInt16 = defaultPort,
    requesterDeviceId: String,
    requesterFingerprint: String,
    targetDeviceId: String,
    sharedSecret: String
) throws -> UnpairResponse {
    let requestID = UUID().uuidString.lowercased()
    let issuedAt = Int64(Date().timeIntervalSince1970 * 1_000)
    var request = UnpairRequest(
        requesterDeviceId: requesterDeviceId,
        requesterFingerprint: requesterFingerprint,
        targetDeviceId: targetDeviceId,
        requestId: requestID,
        issuedAt: issuedAt,
        signature: ""
    )
    let signature = try hmTransAuthenticationCode(
        sharedSecret: sharedSecret,
        purpose: "unpair-control-auth-v1",
        canonicalText: request.canonicalAuthenticationText
    )
    request = UnpairRequest(
        requesterDeviceId: requesterDeviceId,
        requesterFingerprint: requesterFingerprint,
        targetDeviceId: targetDeviceId,
        requestId: requestID,
        issuedAt: issuedAt,
        signature: signature
    )
    let connection = try BlockingNetworkConnection.connect(host: host, port: port)
    defer { connection.cancel() }
    try sendJSONLine(request, connection: connection)
    return try readJSONLine(connection: connection)
}

/// 使用配对时协商的 256 位密钥认证投屏请求。响应只表示 Pad 已接收请求；
/// 真正的视频连接仍会再次走 v0.3 AES-GCM 握手。
public func requestScreenCastStart(
    host: String,
    port: UInt16 = defaultPort,
    requesterDeviceId: String,
    requesterFingerprint: String,
    targetDeviceId: String,
    sharedSecret: String
) throws -> ScreenCastStartResponse {
    let requestID = UUID().uuidString.lowercased()
    let issuedAt = Int64(Date().timeIntervalSince1970 * 1_000)
    var request = ScreenCastStartRequest(
        requesterDeviceId: requesterDeviceId,
        requesterFingerprint: requesterFingerprint,
        targetDeviceId: targetDeviceId,
        requestId: requestID,
        issuedAt: issuedAt,
        signature: ""
    )
    let signature = try screenCastControlSignature(
        sharedSecret: sharedSecret,
        canonicalText: request.canonicalAuthenticationText
    )
    request = ScreenCastStartRequest(
        requesterDeviceId: requesterDeviceId,
        requesterFingerprint: requesterFingerprint,
        targetDeviceId: targetDeviceId,
        requestId: requestID,
        issuedAt: issuedAt,
        signature: signature
    )

    let connection = try BlockingNetworkConnection.connect(host: host, port: port)
    defer { connection.cancel() }
    try sendJSONLine(request, connection: connection)
    let response: ScreenCastStartResponse = try readJSONLine(connection: connection)
    guard response.type == "screen_cast_start_response", response.requestId == requestID else {
        throw HMTransError.protocolError("MatePad 返回了无效投屏响应")
    }
    return response
}

func screenCastControlSignature(sharedSecret: String, canonicalText: String) throws -> String {
    try hmTransAuthenticationCode(
        sharedSecret: sharedSecret,
        purpose: "screen-cast-control-auth-v1",
        canonicalText: canonicalText
    )
}

/// 通过兼容 HMTrans v0.2 的 TCP 线协议发送一个可续传文件载荷。
public func sendFile(
    fileURL: URL,
    host: String,
    port: UInt16 = defaultPort,
    transferId: String = UUID().uuidString,
    senderDeviceId: String? = nil,
    senderName: String? = nil,
    senderPlatform: String? = nil,
    sourceKind: String = "file",
    payloadKind: String = "file",
    sourceName: String? = nil,
    sourceSize: Int64? = nil,
    sourceFileCount: Int? = nil,
    senderFingerprint: String? = nil,
    sharedSecret: String? = nil,
    networkTimeout: TimeInterval = 30,
    control: TransferControl? = nil,
    onProgress: ProgressHandler? = nil
) throws {
    try control?.waitIfNeeded()
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    guard let fileSizeNumber = attributes[.size] as? NSNumber else {
        throw HMTransError.system("无法读取文件大小：\(fileURL.path)")
    }

    let fileSize = fileSizeNumber.int64Value
    let sha256 = try sha256Hex(for: fileURL, control: control)
    let totalChunks = Int((fileSize + Int64(defaultChunkSize) - 1) / Int64(defaultChunkSize))
    let unsignedMeta = FileMeta(
        transferId: transferId,
        senderDeviceId: senderDeviceId,
        senderName: senderName,
        senderPlatform: senderPlatform,
        fileName: fileURL.lastPathComponent,
        fileSize: fileSize,
        sha256: sha256,
        totalChunks: totalChunks,
        resumeSupported: true,
        sourceKind: sourceKind,
        payloadKind: payloadKind,
        sourceName: sourceName ?? fileURL.lastPathComponent,
        sourceSize: sourceSize ?? fileSize,
        sourceFileCount: sourceFileCount ?? 1,
        senderFingerprint: senderFingerprint
    )
    let meta = if let sharedSecret {
        try authenticatedFileMeta(unsignedMeta, sharedSecret: sharedSecret)
    } else {
        unsignedMeta
    }

    let connection = try BlockingNetworkConnection.connect(
        host: host,
        port: port,
        operationTimeout: networkTimeout
    )
    control?.installCancellationHandler { connection.cancel() }
    defer { connection.cancel() }

    try control?.waitIfNeeded()
    try sendJSONLine(meta, connection: connection)

    let decision: ReceiveDecision = try readJSONLine(connection: connection)
    guard decision.accepted else {
        throw HMTransError.rejected("接收方拒绝：\(decision.reason ?? "无原因")")
    }

    let resumeOffset = decision.resumeOffset ?? 0
    guard resumeOffset >= 0, resumeOffset <= fileSize else {
        throw HMTransError.protocolError("接收方返回了无效断点：\(resumeOffset)/\(fileSize)")
    }
    onProgress?(resumeOffset, fileSize)

    try streamFile(
        fileURL,
        connection: connection,
        fileSize: fileSize,
        startingOffset: resumeOffset,
        control: control,
        onProgress: onProgress
    )

    try control?.waitIfNeeded()
    let result: TransferResult = try readJSONLine(connection: connection)
    guard result.type == "transfer_success" else {
        throw HMTransError.protocolError("接收方报告失败：\(result.reason ?? "unknown")")
    }
}

/// 接收单个文件，并在首个连接完成后返回。
public func receiveOneFile(
    port: UInt16 = defaultPort,
    outputDirectory: String = defaultReceiveDirectory(),
    shouldAccept: ReceiveDecisionHandler,
    onProgress: ReceiveProgressHandler? = nil
) throws -> ReceivedFile? {
    try FileManager.default.createDirectory(
        atPath: outputDirectory,
        withIntermediateDirectories: true
    )

    guard let nwPort = NWEndpoint.Port(rawValue: port) else {
        throw HMTransError.usage("无效端口：\(port)")
    }

    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = true
    let listener = try NWListener(using: parameters, on: nwPort)
    let queue = DispatchQueue(label: "HMTrans.ReceiveOne.Listener", qos: .userInitiated)
    let semaphore = DispatchSemaphore(value: 0)
    let box = ListenerBox()

    listener.newConnectionHandler = { connection in
        box.accept(connection)
        semaphore.signal()
    }
    listener.stateUpdateHandler = { state in
        if case .failed(let error) = state {
            box.fail(error)
            semaphore.signal()
        }
    }
    listener.start(queue: queue)
    defer { listener.cancel() }

    semaphore.wait()
    if let error = box.error {
        throw HMTransError.system("监听失败：\(error.localizedDescription)")
    }
    guard let connection = box.connection else {
        throw HMTransError.system("没有可用连接")
    }

    let blocking = try BlockingNetworkConnection(existing: connection)
    defer { blocking.cancel() }
    let firstLine = try blocking.readLine(totalTimeout: 10)
    return try receiveFromConnection(
        connection: blocking,
        outputDirectory: outputDirectory,
        firstLine: firstLine,
        shouldAccept: shouldAccept,
        onProgress: onProgress
    )
}

public final class PersistentFileReceiver: @unchecked Sendable {
    private static let maximumOpenConnections = 16
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "HMTrans.PersistentReceiver", qos: .userInitiated)
    private let connectionQueue = DispatchQueue(
        label: "HMTrans.PersistentReceiver.Connections",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private var listener: NWListener?
    private var running = false
    private var openConnectionCount = 0
    private var acceptedConnections: [ObjectIdentifier: NWConnection] = [:]
    private var activeTransfers: [String: BlockingNetworkConnection] = [:]
    private var pausedTransferIDs: Set<String> = []
    private var cancelledTransferIDs: Set<String> = []

    public init() {}

    public func start(
        port: UInt16 = defaultPort,
        outputDirectory: String = defaultReceiveDirectory(),
        onPairingRequest: PairingRequestHandler? = nil,
        onUnpairRequest: UnpairRequestHandler? = nil,
        shouldAccept: @escaping ReceiveDecisionHandler,
        onProgress: ReceiveProgressHandler? = nil,
        onConnectionResult: @escaping ReceiveCompletionHandler
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw HMTransError.usage("无效端口：\(port)")
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.lock.lock()
            let canAccept = self.openConnectionCount < Self.maximumOpenConnections
            if canAccept {
                self.openConnectionCount += 1
                self.acceptedConnections[ObjectIdentifier(connection)] = connection
            }
            self.lock.unlock()
            guard canAccept else {
                coreLog.warning("Rejected TCP connection because the receiver is at capacity")
                connection.cancel()
                return
            }
            handle(
                connection: connection,
                outputDirectory: outputDirectory,
                onPairingRequest: onPairingRequest,
                onUnpairRequest: onUnpairRequest,
                shouldAccept: shouldAccept,
                onProgress: onProgress,
                onConnectionResult: onConnectionResult
            )
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                coreLog.error("Persistent receiver listener failed: \(error.localizedDescription, privacy: .public)")
                onConnectionResult(.failure(HMTransError.system("监听失败：\(error.localizedDescription)")))
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        running = true
    }

    public func stop() {
        lock.lock()
        let current = listener
        let accepted = Array(acceptedConnections.values)
        let active = Array(activeTransfers.values)
        listener = nil
        acceptedConnections.removeAll()
        activeTransfers.removeAll()
        openConnectionCount = 0
        running = false
        lock.unlock()

        current?.cancel()
        accepted.forEach { $0.cancel() }
        active.forEach { $0.cancel() }
    }

    public var isIdle: Bool {
        lock.lock()
        defer { lock.unlock() }
        return openConnectionCount == 0 && activeTransfers.isEmpty
    }

    /// 暂停接收只关闭数据连接；私有分片会保留，恢复后发送端可协商已保存偏移量。
    public func pauseTransfer(_ transferID: String) {
        lock.lock()
        pausedTransferIDs.insert(transferID)
        let connection = activeTransfers[transferID]
        lock.unlock()
        connection?.cancel()
    }

    public func resumeTransfer(_ transferID: String) {
        lock.lock()
        pausedTransferIDs.remove(transferID)
        cancelledTransferIDs.remove(transferID)
        lock.unlock()
    }

    public func cancelTransfer(_ transferID: String, deletePartial: Bool = false) {
        lock.lock()
        cancelledTransferIDs.insert(transferID)
        pausedTransferIDs.remove(transferID)
        let connection = activeTransfers[transferID]
        lock.unlock()
        connection?.cancel()
        if deletePartial {
            removeStagingFiles(transferID: transferID)
        }
    }

    private func handle(
        connection: NWConnection,
        outputDirectory: String,
        onPairingRequest: PairingRequestHandler?,
        onUnpairRequest: UnpairRequestHandler?,
        shouldAccept: @escaping ReceiveDecisionHandler,
        onProgress: ReceiveProgressHandler?,
        onConnectionResult: @escaping ReceiveCompletionHandler
    ) {
        connectionQueue.async {
            var currentTransferID: String?
            defer {
                self.lock.lock()
                self.acceptedConnections.removeValue(forKey: ObjectIdentifier(connection))
                self.openConnectionCount = max(0, self.openConnectionCount - 1)
                self.lock.unlock()
            }
            do {
                let blocking = try BlockingNetworkConnection(existing: connection)
                defer { blocking.cancel() }
                // 首条控制消息必须在固定总时限内完整到达，不能让慢速逐字节连接
                // 通过反复刷新单次读取超时长期占用接收槽位。
                let firstLine = try blocking.readLine(totalTimeout: 10)
                let envelope = try JSONDecoder().decode(
                    IncomingEnvelope.self,
                    from: Data(firstLine.utf8)
                )
                if envelope.type == "pairing_request" {
                    let request = try JSONDecoder().decode(PairingRequest.self, from: Data(firstLine.utf8))
                    let compatible = request.app == "HMTrans"
                        && request.version == hmTransProtocolVersion
                        && !request.requesterDeviceId.isEmpty
                        && !request.requesterFingerprint.isEmpty
                        && !request.targetDeviceId.isEmpty
                        && !request.targetFingerprint.isEmpty
                        && request.securityVersion == hmTransSecurityVersion
                    guard compatible, let authorization = onPairingRequest?(request) else {
                        try sendJSONLine(PairingChallenge(
                            accepted: false,
                            requestId: request.requestId,
                            reason: compatible ? "pairing_code_expired" : "protocol_incompatible"
                        ), connection: blocking)
                        return
                    }
                    let responder: PairingResponderState
                    do {
                        responder = try PairingResponderState(request: request, code: authorization.code)
                    } catch {
                        try sendJSONLine(PairingChallenge(
                            accepted: false,
                            requestId: request.requestId,
                            reason: "invalid_pairing_handshake"
                        ), connection: blocking)
                        return
                    }
                    try sendJSONLine(responder.challenge, connection: blocking)
                    let confirmation: PairingConfirmation = try readJSONLine(connection: blocking)
                    let accepted = responder.accepts(confirmation)
                    if accepted { authorization.establish(sharedSecret: responder.masterSecret) }
                    try sendJSONLine(PairingResponse(
                        accepted: accepted,
                        reason: accepted ? nil : "invalid_pairing_code"
                    ), connection: blocking)
                    return
                }
                if envelope.type == "unpair_request" {
                    let request = try JSONDecoder().decode(UnpairRequest.self, from: Data(firstLine.utf8))
                    let compatible = request.app == "HMTrans"
                        && request.version == hmTransProtocolVersion
                        && !request.requesterDeviceId.isEmpty
                        && !request.requesterFingerprint.isEmpty
                        && !request.targetDeviceId.isEmpty
                    let accepted = compatible && (onUnpairRequest?(request) ?? false)
                    try sendJSONLine(
                        UnpairResponse(
                            accepted: accepted,
                            reason: accepted ? nil : compatible ? "identity_mismatch" : "protocol_incompatible"
                        ),
                        connection: blocking
                    )
                    return
                }
                let meta = try JSONDecoder().decode(FileMeta.self, from: Data(firstLine.utf8))
                currentTransferID = meta.transferId
                self.lock.lock()
                let isPaused = self.pausedTransferIDs.contains(meta.transferId)
                let isCancelled = self.cancelledTransferIDs.contains(meta.transferId)
                if !isPaused && !isCancelled {
                    self.activeTransfers[meta.transferId] = blocking
                }
                self.lock.unlock()
                if isPaused || isCancelled {
                    try sendJSONLine(
                        ReceiveDecision(
                            accepted: false,
                            reason: isPaused ? "receiver_paused" : "receiver_cancelled"
                        ),
                        connection: blocking
                    )
                    return
                }
                defer {
                    self.lock.lock()
                    self.activeTransfers.removeValue(forKey: meta.transferId)
                    self.lock.unlock()
                }
                let received = try receiveFromConnection(
                    connection: blocking,
                    outputDirectory: outputDirectory,
                    firstLine: firstLine,
                    shouldAccept: shouldAccept,
                    onProgress: onProgress
                )
                onConnectionResult(.success(received))
            } catch {
                coreLog.error("Receive connection failed: \(String(describing: error), privacy: .public)")
                if let currentTransferID {
                    onConnectionResult(.failure(ReceiveConnectionError(
                        transferID: currentTransferID,
                        underlyingDescription: error.localizedDescription
                    )))
                } else {
                    onConnectionResult(.failure(error))
                }
            }
        }
    }
}

private func removeStagingFiles(transferID: String) {
    guard let root = try? FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
    ) else { return }
    let safeID = transferID.replacingOccurrences(
        of: "[^A-Za-z0-9._-]",
        with: "_",
        options: .regularExpression
    )
    let staging = root.appendingPathComponent("HMTrans/Staging", isDirectory: true)
    try? FileManager.default.removeItem(at: staging.appendingPathComponent(safeID).appendingPathExtension("part"))
    try? FileManager.default.removeItem(at: staging.appendingPathComponent(safeID).appendingPathExtension("meta.json"))
}

private struct IncomingEnvelope: Decodable {
    let type: String
}

private final class ListenerBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var connection: NWConnection?
    private(set) var error: Error?

    func accept(_ newConnection: NWConnection) {
        lock.lock()
        defer { lock.unlock() }
        if connection == nil {
            connection = newConnection
        } else {
            newConnection.cancel()
        }
    }

    func fail(_ newError: Error) {
        lock.lock()
        error = newError
        lock.unlock()
    }
}

private final class BlockingNetworkConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let operationTimeout: TimeInterval
    private var inbox = Data()

    static func connect(
        host: String,
        port: UInt16,
        operationTimeout: TimeInterval = 30
    ) throws -> BlockingNetworkConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw HMTransError.usage("无效端口：\(port)")
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        return try BlockingNetworkConnection(
            existing: connection,
            role: "发送端",
            operationTimeout: operationTimeout
        )
    }

    init(
        existing connection: NWConnection,
        role: String = "接收端",
        operationTimeout: TimeInterval = 30
    ) throws {
        self.connection = connection
        self.queue = DispatchQueue(label: "HMTrans.NWConnection.\(UUID().uuidString)", qos: .userInitiated)
        self.operationTimeout = max(0.1, operationTimeout)
        try startAndWait(role: role)
    }

    func cancel() {
        connection.cancel()
    }

    func send(_ data: Data) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<Void>()
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                box.set(.failure(HMTransError.system("send 失败：\(error.localizedDescription)")))
            } else {
                box.set(.success(()))
            }
            semaphore.signal()
        })
        guard semaphore.wait(timeout: .now() + operationTimeout) == .success else {
            connection.cancel()
            throw HMTransError.system("发送超时，对方设备可能已离线")
        }
        try box.value.get()
    }

    func readLine(maxBytes: Int = 64 * 1024, totalTimeout: TimeInterval? = nil) throws -> String {
        let expiresAt = Date().addingTimeInterval(max(0.1, totalTimeout ?? operationTimeout))
        while inbox.count < maxBytes {
            if let newline = inbox.firstIndex(of: 0x0A) {
                let lineData = inbox[..<newline]
                inbox.removeSubrange(..<inbox.index(after: newline))
                return String(decoding: lineData, as: UTF8.self)
            }
            let remaining = expiresAt.timeIntervalSinceNow
            guard remaining > 0 else {
                connection.cancel()
                throw HMTransError.system("控制消息接收超时")
            }
            inbox.append(try readSome(maximumLength: 4096, timeout: remaining))
        }
        throw HMTransError.protocolError("控制消息超过 \(maxBytes) bytes")
    }

    func readPayload(
        to tempURL: URL,
        fileSize: Int64,
        startingOffset: Int64 = 0,
        onProgress: ProgressHandler?
    ) throws {
        if startingOffset == 0 {
            try? FileManager.default.removeItem(at: tempURL)
            guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else {
                throw HMTransError.system("无法创建临时接收文件：\(tempURL.lastPathComponent)")
            }
        }
        let handle = try FileHandle(forWritingTo: tempURL)
        defer { try? handle.close() }

        if startingOffset > 0 {
            try handle.seek(toOffset: UInt64(startingOffset))
        }

        var remaining = fileSize - startingOffset
        var received = startingOffset
        onProgress?(received, fileSize)

        if !inbox.isEmpty, remaining > 0 {
            let count = min(inbox.count, Int(remaining))
            let chunk = inbox.prefix(count)
            try handle.write(contentsOf: chunk)
            inbox.removeSubrange(..<inbox.index(inbox.startIndex, offsetBy: count))
            remaining -= Int64(count)
            received += Int64(count)
            onProgress?(received, fileSize)
        }

        while remaining > 0 {
            let requested = min(defaultChunkSize, Int(remaining))
            let data = try readSome(maximumLength: requested)
            try handle.write(contentsOf: data)
            remaining -= Int64(data.count)
            received += Int64(data.count)
            onProgress?(received, fileSize)
        }
    }

    private func startAndWait(role: String) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<Void>()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                box.set(.success(()))
                semaphore.signal()
            case .failed(let error):
                box.set(.failure(HMTransError.system("连接失败：\(error.localizedDescription)")))
                semaphore.signal()
            case .cancelled:
                box.set(.failure(HMTransError.system("连接已取消")))
                semaphore.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)
        // 调用方可为探测或测试使用更短超时；正式连接的 TCP 握手上限仍为十秒。
        let connectTimeout = min(10, operationTimeout)
        guard semaphore.wait(timeout: .now() + connectTimeout) == .success else {
            connection.cancel()
            throw HMTransError.system("\(role)连接超时")
        }
        try box.value.get()
    }

    private func readSome(maximumLength: Int, timeout: TimeInterval? = nil) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<Data>()
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
            if let error {
                box.set(.failure(HMTransError.system("recv 失败：\(error.localizedDescription)")))
            } else if let data, !data.isEmpty {
                box.set(.success(data))
            } else if isComplete {
                box.set(.failure(HMTransError.protocolError("连接已关闭")))
            } else {
                box.set(.failure(HMTransError.protocolError("读取到空数据")))
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + max(0.1, timeout ?? operationTimeout)) == .success else {
            connection.cancel()
            throw HMTransError.system("接收超时，对方设备可能已离线")
        }
        return try box.value.get()
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?

    var value: Result<T, Error> {
        lock.lock()
        defer { lock.unlock() }
        return result ?? .failure(HMTransError.system("异步操作未返回结果"))
    }

    func set(_ newValue: Result<T, Error>) {
        lock.lock()
        if result == nil {
            result = newValue
        }
        lock.unlock()
    }
}

private func receiveFromConnection(
    connection: BlockingNetworkConnection,
    outputDirectory: String,
    firstLine: String,
    shouldAccept: ReceiveDecisionHandler,
    onProgress: ReceiveProgressHandler?
) throws -> ReceivedFile? {
    let meta = try JSONDecoder().decode(FileMeta.self, from: Data(firstLine.utf8))
    guard meta.type == "file_meta", meta.app == "HMTrans", meta.version == hmTransProtocolVersion,
          !meta.transferId.isEmpty, meta.fileSize >= 0, meta.chunkSize > 0,
          meta.totalChunks >= 0, meta.sha256.count == 64 else {
        throw HMTransError.protocolError("不支持的元数据消息")
    }

    guard shouldAccept(meta) else {
        try sendJSONLine(
            ReceiveDecision(accepted: false, reason: "user_rejected"),
            connection: connection
        )
        return nil
    }

    try FileManager.default.createDirectory(
        atPath: outputDirectory,
        withIntermediateDirectories: true
    )
    let destinationURL = uniqueDestinationURL(
        directory: URL(fileURLWithPath: outputDirectory),
        fileName: meta.fileName
    )
    let stagingRoot = (try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
    ))
        .appendingPathComponent("HMTrans", isDirectory: true)
        .appendingPathComponent("Staging", isDirectory: true)
    try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
    let safeTransferID = meta.transferId.replacingOccurrences(
        of: "[^A-Za-z0-9._-]",
        with: "_",
        options: .regularExpression
    )
    let stagingName = safeTransferID.isEmpty ? UUID().uuidString : safeTransferID
    let tempURL = stagingRoot
        .appendingPathComponent(stagingName)
        .appendingPathExtension("part")
    let metadataURL = stagingRoot
        .appendingPathComponent(stagingName)
        .appendingPathExtension("meta.json")

    var resumeOffset: Int64 = 0
    if meta.resumeSupported == true,
       FileManager.default.fileExists(atPath: tempURL.path),
       FileManager.default.fileExists(atPath: metadataURL.path),
       let savedData = try? Data(contentsOf: metadataURL),
       let savedMeta = try? JSONDecoder().decode(FileMeta.self, from: savedData),
       savedMeta.sha256 == meta.sha256,
       savedMeta.fileSize == meta.fileSize,
       savedMeta.fileName == meta.fileName,
       let partSize = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? NSNumber)?.int64Value,
       partSize >= 0,
       partSize <= meta.fileSize {
        resumeOffset = partSize
    } else {
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.removeItem(at: metadataURL)
    }

    // 保留少量安全空间，避免接收端承诺接收后因发布元数据或最终重命名失败。
    let remainingBytes = max(0, meta.fileSize - resumeOffset)
    let safetyMargin: Int64 = 64 * 1_024 * 1_024
    if let available = try? stagingRoot.resourceValues(
        forKeys: [.volumeAvailableCapacityForImportantUsageKey]
    ).volumeAvailableCapacityForImportantUsage,
       available < remainingBytes + safetyMargin {
        try sendJSONLine(
            ReceiveDecision(
                accepted: false,
                reason: "insufficient_space:required=\(remainingBytes + safetyMargin),available=\(available)"
            ),
            connection: connection
        )
        return nil
    }
    try JSONEncoder().encode(meta).write(to: metadataURL, options: .atomic)

    try sendJSONLine(
        ReceiveDecision(accepted: true, reason: nil, resumeOffset: resumeOffset),
        connection: connection
    )

    try connection.readPayload(
        to: tempURL,
        fileSize: meta.fileSize,
        startingOffset: resumeOffset
    ) { current, total in
        onProgress?(meta, current, total)
    }

    let receivedHash = try sha256Hex(for: tempURL)
    if receivedHash == meta.sha256 {
        let publishedURL = try publishReceivedPayload(
            meta: meta,
            payloadURL: tempURL,
            defaultDestination: destinationURL,
            outputDirectory: URL(fileURLWithPath: outputDirectory, isDirectory: true),
            stagingRoot: stagingRoot
        )
        try? FileManager.default.removeItem(at: metadataURL)
        try sendJSONLine(
            TransferResult(
                type: "transfer_success",
                transferId: meta.transferId,
                sha256: receivedHash,
                reason: nil
            ),
            connection: connection
        )
        return ReceivedFile(meta: meta, url: publishedURL)
    }

    try? FileManager.default.removeItem(at: tempURL)
    try? FileManager.default.removeItem(at: metadataURL)
    try sendJSONLine(
        TransferResult(type: "transfer_failed", transferId: meta.transferId, sha256: receivedHash, reason: "hash_mismatch"),
        connection: connection
    )
    throw HMTransError.protocolError("SHA-256 不一致。期望 \(meta.sha256)，实际 \(receivedHash)")
}

public func sha256Hex(for url: URL, control: TransferControl? = nil) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    var hasher = SHA256()
    while true {
        try control?.waitIfNeeded()
        let data = try handle.read(upToCount: defaultChunkSize) ?? Data()
        if data.isEmpty { break }
        hasher.update(data: data)
    }

    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

public func formatBytes(_ bytes: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(bytes)
    var index = 0
    while value >= 1024, index < units.count - 1 {
        value /= 1024
        index += 1
    }
    return "\(String(format: "%.2f", value)) \(units[index])"
}

private func sendJSONLine<T: Encodable>(_ value: T, connection: BlockingNetworkConnection) throws {
    var data = try JSONEncoder().encode(value)
    data.append(0x0A)
    try connection.send(data)
}

private func readJSONLine<T: Decodable>(connection: BlockingNetworkConnection) throws -> T {
    let line = try connection.readLine()
    guard let data = line.data(using: .utf8) else {
        throw HMTransError.protocolError("消息不是有效 UTF-8")
    }
    return try JSONDecoder().decode(T.self, from: data)
}

private func streamFile(
    _ fileURL: URL,
    connection: BlockingNetworkConnection,
    fileSize: Int64,
    startingOffset: Int64,
    control: TransferControl?,
    onProgress: ProgressHandler?
) throws {
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { try? handle.close() }

    if startingOffset > 0 {
        try handle.seek(toOffset: UInt64(startingOffset))
    }

    var sent = startingOffset
    while true {
        try control?.waitIfNeeded()
        let data = try handle.read(upToCount: defaultChunkSize) ?? Data()
        if data.isEmpty { break }
        try control?.waitIfNeeded()
        try connection.send(data)
        sent += Int64(data.count)
        onProgress?(sent, fileSize)
    }
}
