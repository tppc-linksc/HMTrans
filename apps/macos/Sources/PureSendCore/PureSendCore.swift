import CryptoKit
import Foundation
import Network
import OSLog

public let defaultPort: UInt16 = 51888
public let defaultChunkSize = 1_048_576
public let discoveryPort: UInt16 = 51889
public let pureSendProtocolVersion = "0.1.0"

private let coreLog = Logger(subsystem: "com.linksc.puresend", category: "transfer")

public enum PureSendError: Error, CustomStringConvertible {
    case usage(String)
    case system(String)
    case protocolError(String)
    case rejected(String)

    public var description: String {
        switch self {
        case .usage(let message), .system(let message), .protocolError(let message), .rejected(let message):
            return message
        }
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

    public init(
        type: String = "file_meta",
        app: String = "PureSend",
        version: String = pureSendProtocolVersion,
        transferId: String,
        senderDeviceId: String? = nil,
        senderName: String? = nil,
        senderPlatform: String? = nil,
        fileName: String,
        fileSize: Int64,
        sha256: String,
        chunkSize: Int = defaultChunkSize,
        totalChunks: Int
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
    }
}

/// Receiver response after checking trust and user confirmation.
public struct ReceiveDecision: Codable, Sendable {
    public let type: String
    public let accepted: Bool
    public let reason: String?

    public init(type: String = "receive_decision", accepted: Bool, reason: String?) {
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
public typealias ReceiveCompletionHandler = @Sendable (_ result: Result<ReceivedFile?, Error>) -> Void

public func defaultReceiveDirectory() -> String {
    NSString(string: "~/Downloads/PureSend").expandingTildeInPath
}

/// Sends one file over a Network.framework TCP connection using the PureSend v0.1 wire protocol.
public func sendFile(
    fileURL: URL,
    host: String,
    port: UInt16 = defaultPort,
    senderDeviceId: String? = nil,
    senderName: String? = nil,
    senderPlatform: String? = nil,
    onProgress: ProgressHandler? = nil
) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    guard let fileSizeNumber = attributes[.size] as? NSNumber else {
        throw PureSendError.system("无法读取文件大小：\(fileURL.path)")
    }

    let fileSize = fileSizeNumber.int64Value
    let sha256 = try sha256Hex(for: fileURL)
    let totalChunks = Int((fileSize + Int64(defaultChunkSize) - 1) / Int64(defaultChunkSize))
    let meta = FileMeta(
        transferId: UUID().uuidString,
        senderDeviceId: senderDeviceId,
        senderName: senderName,
        senderPlatform: senderPlatform,
        fileName: fileURL.lastPathComponent,
        fileSize: fileSize,
        sha256: sha256,
        totalChunks: totalChunks
    )

    let connection = try BlockingNetworkConnection.connect(host: host, port: port)
    defer { connection.cancel() }

    try sendJSONLine(meta, connection: connection)

    let decision: ReceiveDecision = try readJSONLine(connection: connection)
    guard decision.accepted else {
        throw PureSendError.rejected("接收方拒绝：\(decision.reason ?? "无原因")")
    }

    try streamFile(fileURL, connection: connection, fileSize: fileSize, onProgress: onProgress)

    let result: TransferResult = try readJSONLine(connection: connection)
    guard result.type == "transfer_success" else {
        throw PureSendError.protocolError("接收方报告失败：\(result.reason ?? "unknown")")
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
        throw PureSendError.usage("无效端口：\(port)")
    }

    let listener = try NWListener(using: .tcp, on: nwPort)
    let queue = DispatchQueue(label: "PureSend.ReceiveOne.Listener", qos: .userInitiated)
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
        throw PureSendError.system("监听失败：\(error.localizedDescription)")
    }
    guard let connection = box.connection else {
        throw PureSendError.system("没有可用连接")
    }

    let blocking = try BlockingNetworkConnection(existing: connection)
    defer { blocking.cancel() }
    return try receiveFromConnection(
        connection: blocking,
        outputDirectory: outputDirectory,
        shouldAccept: shouldAccept,
        onProgress: onProgress
    )
}

public final class PersistentFileReceiver: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "PureSend.PersistentReceiver", qos: .userInitiated)
    private var listener: NWListener?
    private var running = false

    public init() {}

    public func start(
        port: UInt16 = defaultPort,
        outputDirectory: String = defaultReceiveDirectory(),
        shouldAccept: @escaping ReceiveDecisionHandler,
        onProgress: ReceiveProgressHandler? = nil,
        onConnectionResult: @escaping ReceiveCompletionHandler
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw PureSendError.usage("无效端口：\(port)")
        }

        let listener = try NWListener(using: .tcp, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(
                connection: connection,
                outputDirectory: outputDirectory,
                shouldAccept: shouldAccept,
                onProgress: onProgress,
                onConnectionResult: onConnectionResult
            )
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                coreLog.error("Persistent receiver listener failed: \(error.localizedDescription, privacy: .public)")
                onConnectionResult(.failure(PureSendError.system("监听失败：\(error.localizedDescription)")))
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        running = true
    }

    public func stop() {
        lock.lock()
        let current = listener
        listener = nil
        running = false
        lock.unlock()

        current?.cancel()
    }

    private func handle(
        connection: NWConnection,
        outputDirectory: String,
        shouldAccept: @escaping ReceiveDecisionHandler,
        onProgress: ReceiveProgressHandler?,
        onConnectionResult: @escaping ReceiveCompletionHandler
    ) {
        queue.async {
            do {
                let blocking = try BlockingNetworkConnection(existing: connection)
                defer { blocking.cancel() }
                let received = try receiveFromConnection(
                    connection: blocking,
                    outputDirectory: outputDirectory,
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
            throw PureSendError.usage("无效端口：\(port)")
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        return try BlockingNetworkConnection(existing: connection)
    }

    init(existing connection: NWConnection) throws {
        self.connection = connection
        self.queue = DispatchQueue(label: "PureSend.NWConnection.\(UUID().uuidString)", qos: .userInitiated)
        try startAndWait()
    }

    func cancel() {
        connection.cancel()
    }

    func send(_ data: Data) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<Void>()
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                box.set(.failure(PureSendError.system("send 失败：\(error.localizedDescription)")))
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
        throw PureSendError.protocolError("控制消息超过 \(maxBytes) bytes")
    }

    func readPayload(to tempURL: URL, fileSize: Int64, onProgress: ProgressHandler?) throws {
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tempURL)
        defer { try? handle.close() }

        var remaining = fileSize
        var received: Int64 = 0

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

    private func startAndWait() throws {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<Void>()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                box.set(.success(()))
                semaphore.signal()
            case .failed(let error):
                box.set(.failure(PureSendError.system("连接失败：\(error.localizedDescription)")))
                semaphore.signal()
            case .cancelled:
                box.set(.failure(PureSendError.system("连接已取消")))
                semaphore.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)
        guard semaphore.wait(timeout: .now() + 10) == .success else {
            connection.cancel()
            throw PureSendError.system("连接超时")
        }
        try box.value.get()
    }

    private func readSome(maximumLength: Int) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<Data>()
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
            if let error {
                box.set(.failure(PureSendError.system("recv 失败：\(error.localizedDescription)")))
            } else if let data, !data.isEmpty {
                box.set(.success(data))
            } else if isComplete {
                box.set(.failure(PureSendError.protocolError("连接已关闭")))
            } else {
                box.set(.failure(PureSendError.protocolError("读取到空数据")))
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
        return result ?? .failure(PureSendError.system("异步操作未返回结果"))
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
    shouldAccept: ReceiveDecisionHandler,
    onProgress: ReceiveProgressHandler?
) throws -> ReceivedFile? {
    let meta: FileMeta = try readJSONLine(connection: connection)
    guard meta.type == "file_meta", meta.app == "PureSend" else {
        throw PureSendError.protocolError("不支持的元数据消息")
    }

    guard shouldAccept(meta) else {
        try sendJSONLine(
            ReceiveDecision(accepted: false, reason: "user_rejected"),
            connection: connection
        )
        return nil
    }

    try sendJSONLine(
        ReceiveDecision(accepted: true, reason: nil),
        connection: connection
    )

    try FileManager.default.createDirectory(
        atPath: outputDirectory,
        withIntermediateDirectories: true
    )
    let destinationURL = uniqueDestinationURL(
        directory: URL(fileURLWithPath: outputDirectory),
        fileName: meta.fileName
    )
    let tempURL = destinationURL.appendingPathExtension("part")

    try connection.readPayload(to: tempURL, fileSize: meta.fileSize) { current, total in
        onProgress?(meta, current, total)
    }

    let receivedHash = try sha256Hex(for: tempURL)
    if receivedHash == meta.sha256 {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
        try sendJSONLine(
            TransferResult(type: "transfer_success", transferId: meta.transferId, sha256: receivedHash, reason: nil),
            connection: connection
        )
        return ReceivedFile(meta: meta, url: destinationURL)
    }

    try? FileManager.default.removeItem(at: tempURL)
    try sendJSONLine(
        TransferResult(type: "transfer_failed", transferId: meta.transferId, sha256: receivedHash, reason: "hash_mismatch"),
        connection: connection
    )
    throw PureSendError.protocolError("SHA-256 不一致。期望 \(meta.sha256)，实际 \(receivedHash)")
}

public func sha256Hex(for url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    var hasher = SHA256()
    while true {
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
        throw PureSendError.protocolError("消息不是有效 UTF-8")
    }
    return try JSONDecoder().decode(T.self, from: data)
}

private func streamFile(
    _ fileURL: URL,
    connection: BlockingNetworkConnection,
    fileSize: Int64,
    onProgress: ProgressHandler?
) throws {
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { try? handle.close() }

    var sent: Int64 = 0
    while true {
        let data = try handle.read(upToCount: defaultChunkSize) ?? Data()
        if data.isEmpty { break }
        try connection.send(data)
        sent += Int64(data.count)
        onProgress?(sent, fileSize)
    }
}

private func uniqueDestinationURL(directory: URL, fileName: String) -> URL {
    let safeName = URL(fileURLWithPath: fileName).lastPathComponent
    let base = directory.appendingPathComponent(safeName)
    if !FileManager.default.fileExists(atPath: base.path) {
        return base
    }

    let ext = base.pathExtension
    let stem = base.deletingPathExtension().lastPathComponent
    var index = 1
    while true {
        let candidateName = ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
        let candidate = directory.appendingPathComponent(candidateName)
        if !FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        index += 1
    }
}
