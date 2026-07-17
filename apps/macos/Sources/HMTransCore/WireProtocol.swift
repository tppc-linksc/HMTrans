import Foundation

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

/// 界面命令与文件传输循环共享的线程安全用户控制器。
public final class TransferControl: @unchecked Sendable {
    private let condition = NSCondition()
    private var paused = false
    private var cancelled = false
    private var cancellationHandler: (@Sendable () -> Void)?

    public init() {}

    public var isPaused: Bool {
        condition.lock(); defer { condition.unlock() }
        return paused
    }

    public var isCancelled: Bool {
        condition.lock(); defer { condition.unlock() }
        return cancelled
    }

    public func pause() {
        condition.lock(); if !cancelled { paused = true }; condition.unlock()
    }

    public func resume() {
        condition.lock(); paused = false; condition.broadcast(); condition.unlock()
    }

    public func cancel() {
        let handler: (@Sendable () -> Void)?
        condition.lock()
        cancelled = true; paused = false; handler = cancellationHandler
        condition.broadcast(); condition.unlock()
        handler?()
    }

    func installCancellationHandler(_ handler: @escaping @Sendable () -> Void) {
        condition.lock()
        cancellationHandler = handler
        let cancelImmediately = cancelled
        condition.unlock()
        if cancelImmediately { handler() }
    }

    func waitIfNeeded() throws {
        condition.lock()
        while paused && !cancelled { condition.wait() }
        let shouldCancel = cancelled
        condition.unlock()
        if shouldCancel { throw HMTransError.cancelled }
    }
}

/// 已部署的 0.2 线协议元数据。JSON 使用换行分隔，只有接收端返回 ReceiveDecision 后才发送文件字节。
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
        type: String = "file_meta", app: String = "HMTrans", version: String = hmTransProtocolVersion,
        transferId: String, senderDeviceId: String? = nil, senderName: String? = nil,
        senderPlatform: String? = nil, fileName: String, fileSize: Int64, sha256: String,
        chunkSize: Int = defaultChunkSize, totalChunks: Int, resumeSupported: Bool? = true,
        sourceKind: String? = "file", payloadKind: String? = "file", sourceName: String? = nil,
        sourceSize: Int64? = nil, sourceFileCount: Int? = nil, senderFingerprint: String? = nil
    ) {
        self.type = type; self.app = app; self.version = version; self.transferId = transferId
        self.senderDeviceId = senderDeviceId; self.senderName = senderName; self.senderPlatform = senderPlatform
        self.fileName = fileName; self.fileSize = fileSize; self.sha256 = sha256
        self.chunkSize = chunkSize; self.totalChunks = totalChunks; self.resumeSupported = resumeSupported
        self.sourceKind = sourceKind; self.payloadKind = payloadKind; self.sourceName = sourceName
        self.sourceSize = sourceSize; self.sourceFileCount = sourceFileCount
        self.senderFingerprint = senderFingerprint
    }
}

public struct ReceiveDecision: Codable, Sendable {
    public let type: String
    public let accepted: Bool
    public let reason: String?
    public let resumeOffset: Int64?

    public init(type: String = "receive_decision", accepted: Bool, reason: String?, resumeOffset: Int64? = nil) {
        self.type = type; self.accepted = accepted; self.reason = reason; self.resumeOffset = resumeOffset
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
    public let pairingSecret: String?

    public init(
        type: String = "pairing_request", app: String = "HMTrans", version: String = hmTransProtocolVersion,
        requesterDeviceId: String, requesterName: String, requesterPlatform: String,
        requesterSystemVersion: String, requesterIP: String, requesterPort: UInt16, code: String,
        requesterFingerprint: String? = nil, pairingSecret: String? = nil
    ) {
        self.type = type; self.app = app; self.version = version; self.requesterDeviceId = requesterDeviceId
        self.requesterName = requesterName; self.requesterPlatform = requesterPlatform
        self.requesterSystemVersion = requesterSystemVersion; self.requesterIP = requesterIP
        self.requesterPort = requesterPort; self.code = code; self.requesterFingerprint = requesterFingerprint
        self.pairingSecret = pairingSecret
    }
}

public struct PairingResponse: Codable, Sendable {
    public let type: String
    public let accepted: Bool
    public let reason: String?

    public init(type: String = "pairing_response", accepted: Bool, reason: String? = nil) {
        self.type = type; self.accepted = accepted; self.reason = reason
    }
}

/// 已配对设备发送的主动解除配对控制帧。接收端必须先校验稳定设备 ID 和身份指纹。
public struct UnpairRequest: Codable, Sendable {
    public let type: String
    public let app: String
    public let version: String
    public let requesterDeviceId: String
    public let requesterFingerprint: String
    public let targetDeviceId: String

    public init(
        type: String = "unpair_request", app: String = "HMTrans", version: String = hmTransProtocolVersion,
        requesterDeviceId: String, requesterFingerprint: String, targetDeviceId: String
    ) {
        self.type = type
        self.app = app
        self.version = version
        self.requesterDeviceId = requesterDeviceId
        self.requesterFingerprint = requesterFingerprint
        self.targetDeviceId = targetDeviceId
    }
}

public struct UnpairResponse: Codable, Sendable {
    public let type: String
    public let accepted: Bool
    public let reason: String?

    public init(type: String = "unpair_response", accepted: Bool, reason: String? = nil) {
        self.type = type
        self.accepted = accepted
        self.reason = reason
    }
}

/// Mac 通过已配对控制端口请求 MatePad 开始投屏。签名覆盖全部字段，
/// Pad 还会校验时间窗口和一次性 requestId，局域网内的未配对设备不能伪造请求。
public struct ScreenCastStartRequest: Codable, Sendable {
    public let type: String
    public let app: String
    public let version: String
    public let requesterDeviceId: String
    public let requesterFingerprint: String
    public let targetDeviceId: String
    public let requestId: String
    public let issuedAt: Int64
    public let signature: String

    public init(
        type: String = "screen_cast_start_request",
        app: String = "HMTrans",
        version: String = hmTransProtocolVersion,
        requesterDeviceId: String,
        requesterFingerprint: String,
        targetDeviceId: String,
        requestId: String,
        issuedAt: Int64,
        signature: String
    ) {
        self.type = type
        self.app = app
        self.version = version
        self.requesterDeviceId = requesterDeviceId
        self.requesterFingerprint = requesterFingerprint
        self.targetDeviceId = targetDeviceId
        self.requestId = requestId
        self.issuedAt = issuedAt
        self.signature = signature
    }

    public var canonicalAuthenticationText: String {
        [type, app, version, requesterDeviceId, requesterFingerprint, targetDeviceId, requestId, String(issuedAt)]
            .joined(separator: "|")
    }
}

public struct ScreenCastStartResponse: Codable, Sendable {
    public let type: String
    public let accepted: Bool
    public let requestId: String
    public let reason: String?

    public init(
        type: String = "screen_cast_start_response",
        accepted: Bool,
        requestId: String,
        reason: String? = nil
    ) {
        self.type = type
        self.accepted = accepted
        self.requestId = requestId
        self.reason = reason
    }
}

public struct TransferResult: Codable, Sendable {
    public let type: String
    public let transferId: String
    public let sha256: String?
    public let reason: String?

    public init(type: String, transferId: String, sha256: String?, reason: String?) {
        self.type = type; self.transferId = transferId; self.sha256 = sha256; self.reason = reason
    }
}

public struct ReceivedFile: Sendable {
    public let meta: FileMeta
    public let url: URL
}

/// 将接收连接错误绑定到线上任务 ID，避免并发接收时把错误归到另一台设备的任务。
public struct ReceiveConnectionError: LocalizedError, Sendable {
    public let transferID: String
    public let underlyingDescription: String

    public init(transferID: String, underlyingDescription: String) {
        self.transferID = transferID
        self.underlyingDescription = underlyingDescription
    }

    public var errorDescription: String? { underlyingDescription }
}

public typealias ProgressHandler = @Sendable (_ current: Int64, _ total: Int64) -> Void
public typealias ReceiveProgressHandler = @Sendable (_ meta: FileMeta, _ current: Int64, _ total: Int64) -> Void
public typealias ReceiveDecisionHandler = @Sendable (_ meta: FileMeta) -> Bool
public typealias PairingRequestHandler = @Sendable (_ request: PairingRequest) -> Bool
public typealias UnpairRequestHandler = @Sendable (_ request: UnpairRequest) -> Bool
public typealias ReceiveCompletionHandler = @Sendable (_ result: Result<ReceivedFile?, Error>) -> Void
