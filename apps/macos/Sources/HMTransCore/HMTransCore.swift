import CryptoKit
import Foundation
import Network
import OSLog

public let defaultPort: UInt16 = 51888
public let defaultChunkSize = 1_048_576
public let discoveryPort: UInt16 = 51889
public let hmTransProtocolVersion = "0.2.0"

private let coreLog = Logger(subsystem: "com.linksc.hmtrans", category: "transfer")

public enum HMTransError: Error, CustomStringConvertible {
    case usage(String)
    case system(String)
    case protocolError(String)
    case rejected(String)
    case cancelled

    public var description: String {
        switch self {
        case .usage(let message), .system(let message), .protocolError(let message), .rejected(let message):
            return message
        case .cancelled:
            return "传输已取消"
        }
    }
}

/// Thread-safe control shared by the UI and the blocking transfer loop.
/// Pause stops file reads and socket writes at the next chunk boundary; cancel
/// also closes the active connection so a blocked network operation is released.
public final class TransferControl: @unchecked Sendable {
    private let condition = NSCondition()
    private var paused = false
    private var cancelled = false
    private var cancellationHandler: (@Sendable () -> Void)?

    public init() {}

    public var isPaused: Bool {
        condition.lock()
        defer { condition.unlock() }
        return paused
    }

    public var isCancelled: Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelled
    }

    public func pause() {
        condition.lock()
        if !cancelled { paused = true }
        condition.unlock()
    }

    public func resume() {
        condition.lock()
        paused = false
        condition.broadcast()
        condition.unlock()
    }

    public func cancel() {
        let handler: (@Sendable () -> Void)?
        condition.lock()
        cancelled = true
        paused = false
        handler = cancellationHandler
        condition.broadcast()
        condition.unlock()
        handler?()
    }

    fileprivate func installCancellationHandler(_ handler: @escaping @Sendable () -> Void) {
        let cancelImmediately: Bool
        condition.lock()
        cancellationHandler = handler
        cancelImmediately = cancelled
        condition.unlock()
        if cancelImmediately { handler() }
    }

    fileprivate func waitIfNeeded() throws {
        condition.lock()
        while paused && !cancelled {
            condition.wait()
        }
        let shouldCancel = cancelled
        condition.unlock()
        if shouldCancel { throw HMTransError.cancelled }
    }
}

/// Wire-format metadata sent before the raw file payload.
public struct FileMeta: Codable, Sendable {
    public let type: String
    public let app: String
    public let version: String
    public let transferId: String
    public let senderDeviceId: String?
    public let senderName: String?
    public let senderPlatform: String?
    public let fileName: String
    public let fileSize: Int64
    public let sha256: String
    public let chunkSize: Int
    public let totalChunks: Int
    public let resumeSupported: Bool?
    public let sourceKind: String?
    public let payloadKind: String?
    public let sourceName: String?
    public let sourceSize: Int64?
    public let sourceFileCount: Int?
    public let senderFingerprint: String?

    public init(
        type: String = "file_meta",
        app: String = "HMTrans",
        version: String = hmTransProtocolVersion,
        transferId: String,
        senderDeviceId: String? = nil,
        senderName: String? = nil,
        senderPlatform: String? = nil,
        fileName: String,
        fileSize: Int64,
        sha256: String,
        chunkSize: Int = defaultChunkSize,
        totalChunks: Int,
        resumeSupported: Bool? = true,
        sourceKind: String? = "file",
        payloadKind: String? = "file",
        sourceName: String? = nil,
        sourceSize: Int64? = nil,
        sourceFileCount: Int? = nil,
        senderFingerprint: String? = nil
    ) {
        self.type = type
        self.app = app
        self.version = version
        self.transferId = transferId
        self.senderDeviceId = senderDeviceId
        self.senderName = senderName
        self.senderPlatform = senderPlatform
        self.fileName = fileName
        self.fileSize = fileSize
        self.sha256 = sha256
        self.chunkSize = chunkSize
        self.totalChunks = totalChunks
        self.resumeSupported = resumeSupported
        self.sourceKind = sourceKind
        self.payloadKind = payloadKind
        self.sourceName = sourceName
        self.sourceSize = sourceSize
        self.sourceFileCount = sourceFileCount
        self.senderFingerprint = senderFingerprint
    }
}

/// Receiver response after checking trust and user confirmation.
public struct ReceiveDecision: Codable, Sendable {
    public let type: String
    public let accepted: Bool
    public let reason: String?
    public let resumeOffset: Int64?

    public init(
        type: String = "receive_decision",
        accepted: Bool,
        reason: String?,
        resumeOffset: Int64? = nil
    ) {
        self.type = type
        self.accepted = accepted
        self.reason = reason
        self.resumeOffset = resumeOffset
    }
}

public struct PairingRequest: Codable, Sendable {
    public let type: String
    public let app: String
    public let version: String
    public let requesterDeviceId: String
    public let requesterName: String
    public let requesterPlatform: String
    public let requesterSystemVersion: String
    public let requesterIP: String
    public let requesterPort: UInt16
    public let code: String
    public let requesterFingerprint: String?

    public init(
        type: String = "pairing_request",
        app: String = "HMTrans",
        version: String = hmTransProtocolVersion,
        requesterDeviceId: String,
        requesterName: String,
        requesterPlatform: String,
        requesterSystemVersion: String,
        requesterIP: String,
        requesterPort: UInt16,
        code: String,
        requesterFingerprint: String? = nil
    ) {
        self.type = type
        self.app = app
        self.version = version
        self.requesterDeviceId = requesterDeviceId
        self.requesterName = requesterName
        self.requesterPlatform = requesterPlatform
        self.requesterSystemVersion = requesterSystemVersion
        self.requesterIP = requesterIP
        self.requesterPort = requesterPort
        self.code = code
        self.requesterFingerprint = requesterFingerprint
    }
}

public struct PairingResponse: Codable, Sendable {
    public let type: String
    public let accepted: Bool
    public let reason: String?

    public init(type: String = "pairing_response", accepted: Bool, reason: String? = nil) {
        self.type = type
        self.accepted = accepted
        self.reason = reason
    }
}

/// Final checksum result sent by the receiver after the payload is written.
public struct TransferResult: Codable, Sendable {
    public let type: String
    public let transferId: String
    public let sha256: String?
    public let reason: String?

    public init(type: String, transferId: String, sha256: String?, reason: String?) {
        self.type = type
        self.transferId = transferId
        self.sha256 = sha256
        self.reason = reason
    }
}

public struct ReceivedFile: Sendable {
    public let meta: FileMeta
    public let url: URL
}

public typealias ProgressHandler = @Sendable (_ current: Int64, _ total: Int64) -> Void
public typealias ReceiveProgressHandler = @Sendable (_ meta: FileMeta, _ current: Int64, _ total: Int64) -> Void
public typealias ReceiveDecisionHandler = @Sendable (_ meta: FileMeta) -> Bool
public typealias PairingRequestHandler = @Sendable (_ request: PairingRequest) -> Bool
public typealias ReceiveCompletionHandler = @Sendable (_ result: Result<ReceivedFile?, Error>) -> Void

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
    requesterFingerprint: String? = nil
) throws -> PairingResponse {
    let connection = try BlockingNetworkConnection.connect(host: host, port: port)
    defer { connection.cancel() }
    try sendJSONLine(
        PairingRequest(
            requesterDeviceId: requesterDeviceId,
            requesterName: requesterName,
            requesterPlatform: requesterPlatform,
            requesterSystemVersion: requesterSystemVersion,
            requesterIP: requesterIP,
            requesterPort: requesterPort,
            code: code.filter(\.isNumber),
            requesterFingerprint: requesterFingerprint
        ),
        connection: connection
    )
    return try readJSONLine(connection: connection)
}

/// Sends one resumable file payload over the HMTrans v0.2-compatible TCP wire protocol.
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
    let meta = FileMeta(
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

    let connection = try BlockingNetworkConnection.connect(host: host, port: port)
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

/// Receives a single file and returns after the first connection completes.
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
    let firstLine = try blocking.readLine()
    return try receiveFromConnection(
        connection: blocking,
        outputDirectory: outputDirectory,
        firstLine: firstLine,
        shouldAccept: shouldAccept,
        onProgress: onProgress
    )
}

public final class PersistentFileReceiver: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "HMTrans.PersistentReceiver", qos: .userInitiated)
    private var listener: NWListener?
    private var running = false
    private var activeTransfers: [String: BlockingNetworkConnection] = [:]
    private var pausedTransferIDs: Set<String> = []
    private var cancelledTransferIDs: Set<String> = []

    public init() {}

    public func start(
        port: UInt16 = defaultPort,
        outputDirectory: String = defaultReceiveDirectory(),
        onPairingRequest: PairingRequestHandler? = nil,
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
            self?.handle(
                connection: connection,
                outputDirectory: outputDirectory,
                onPairingRequest: onPairingRequest,
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
        let active = Array(activeTransfers.values)
        listener = nil
        activeTransfers.removeAll()
        running = false
        lock.unlock()

        current?.cancel()
        active.forEach { $0.cancel() }
    }

    /// Pausing a receive closes only its data connection. The private part file
    /// remains and the sender can negotiate the saved offset after resume.
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
        shouldAccept: @escaping ReceiveDecisionHandler,
        onProgress: ReceiveProgressHandler?,
        onConnectionResult: @escaping ReceiveCompletionHandler
    ) {
        queue.async {
            do {
                let blocking = try BlockingNetworkConnection(existing: connection)
                defer { blocking.cancel() }
                let firstLine = try blocking.readLine()
                let envelope = try JSONDecoder().decode(
                    IncomingEnvelope.self,
                    from: Data(firstLine.utf8)
                )
                if envelope.type == "pairing_request" {
                    let request = try JSONDecoder().decode(PairingRequest.self, from: Data(firstLine.utf8))
                    let accepted = onPairingRequest?(request) ?? false
                    try sendJSONLine(
                        PairingResponse(accepted: accepted, reason: accepted ? nil : "invalid_pairing_code"),
                        connection: blocking
                    )
                    return
                }
                let meta = try JSONDecoder().decode(FileMeta.self, from: Data(firstLine.utf8))
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
                onConnectionResult(.failure(error))
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
    private var inbox = Data()

    static func connect(host: String, port: UInt16) throws -> BlockingNetworkConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw HMTransError.usage("无效端口：\(port)")
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        return try BlockingNetworkConnection(existing: connection, role: "发送端")
    }

    init(existing connection: NWConnection, role: String = "接收端") throws {
        self.connection = connection
        self.queue = DispatchQueue(label: "HMTrans.NWConnection.\(UUID().uuidString)", qos: .userInitiated)
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
        semaphore.wait()
        try box.value.get()
    }

    func readLine(maxBytes: Int = 64 * 1024) throws -> String {
        while inbox.count < maxBytes {
            if let newline = inbox.firstIndex(of: 0x0A) {
                let lineData = inbox[..<newline]
                inbox.removeSubrange(..<inbox.index(after: newline))
                return String(decoding: lineData, as: UTF8.self)
            }
            inbox.append(try readSome(maximumLength: 4096))
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
            FileManager.default.createFile(atPath: tempURL.path, contents: nil)
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
        guard semaphore.wait(timeout: .now() + 10) == .success else {
            connection.cancel()
            throw HMTransError.system("\(role)连接超时")
        }
        try box.value.get()
    }

    private func readSome(maximumLength: Int) throws -> Data {
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
        semaphore.wait()
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
    guard meta.type == "file_meta", meta.app == "HMTrans" else {
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

    // Keep a small safety margin so publishing metadata and the final rename do
    // not fail after the receiver has already promised to accept the payload.
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
