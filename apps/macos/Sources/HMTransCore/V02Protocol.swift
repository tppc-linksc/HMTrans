import Foundation

public enum HMTransV02 {
    public static let app = "HMTrans"
    public static let protocolVersion = "0.2.0"
    public static let protocolMin = "0.1.0"
    public static let discoveryPort: UInt16 = 51_889
    public static let transferPort: UInt16 = 51_888
    public static let defaultChunkSize = 1_048_576
}

public struct V02MessageHeader: Codable, Sendable {
    public let type: String
    public let app: String
    public let protocolVersion: String
    public let messageId: String
    public let timestamp: Int64

    public init(type: String, messageId: String = UUID().uuidString, timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)) {
        self.type = type
        app = HMTransV02.app
        protocolVersion = HMTransV02.protocolVersion
        self.messageId = messageId
        self.timestamp = timestamp
    }
}

public struct V02DiscoveryBeacon: Codable, Sendable {
    public let type: String
    public let app: String
    public let protocolMin: String
    public let protocolMax: String
    public let deviceId: String
    public let deviceName: String
    public let platform: String
    public let systemVersion: String
    public let ip: String
    public let port: UInt16
    public let receiverState: String
    public let pairingRequired: Bool
    public let capabilities: [String]
    public let timestamp: Int64
}

public struct V02TransferOffer: Codable, Sendable {
    public let type: String
    public let app: String
    public let protocolVersion: String
    public let messageId: String
    public let timestamp: Int64
    public let transferId: String
    public let groupId: String?
    public let senderDeviceId: String
    public let receiverDeviceId: String
    public let sourceKind: String
    public let payloadKind: String
    public let displayName: String
    public let sourceSize: Int64
    public let sourceFileCount: Int
    public let payloadSize: Int64
    public let payloadSha256: String
    public let chunkSize: Int
    public let resumeSupported: Bool
}

public struct V02TransferAccept: Codable, Sendable {
    public let type: String
    public let app: String
    public let protocolVersion: String
    public let messageId: String
    public let timestamp: Int64
    public let transferId: String
    public let resumeOffset: Int64
    public let lastCompleteChunkSha256: String?
    public let reservedName: String
}

public struct V02TransferCommand: Codable, Sendable {
    public let type: String
    public let app: String
    public let protocolVersion: String
    public let messageId: String
    public let timestamp: Int64
    public let transferId: String
    public let command: String
    public let deletePartial: Bool
}

public struct V02TransferResult: Codable, Sendable {
    public let type: String
    public let app: String
    public let protocolVersion: String
    public let messageId: String
    public let timestamp: Int64
    public let transferId: String
    public let success: Bool
    public let payloadSha256: String?
    public let savedName: String?
    public let reason: String?
    public let retryable: Bool
}
