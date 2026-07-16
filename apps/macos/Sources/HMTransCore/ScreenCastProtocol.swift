import CryptoKit
import Foundation

public let defaultScreenCastPort: UInt16 = 51_890
public let screenCastProtocolVersion = "0.3.0"
public let screenCastHeaderLength = 32
public let screenCastControlPayloadLimit = 64 * 1024
public let screenCastMediaPayloadLimit = 8 * 1024 * 1024

public enum ScreenCastMessageType: UInt8, Sendable {
    case hello = 1
    case ack = 2
    case videoConfig = 3
    case videoFrame = 4
    case streamControl = 5
    case heartbeat = 6
    case error = 7
    case end = 8
}

public struct ScreenCastPacketFlags: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let encrypted = ScreenCastPacketFlags(rawValue: 1 << 0)
    public static let keyFrame = ScreenCastPacketFlags(rawValue: 1 << 1)
    public static let codecConfig = ScreenCastPacketFlags(rawValue: 1 << 2)
}

public enum ScreenCastProtocolError: LocalizedError, Sendable {
    case invalidHeader
    case unsupportedVersion
    case payloadTooLarge
    case invalidSecret
    case decryptionFailed

    public var errorDescription: String? {
        switch self {
        case .invalidHeader: "投屏数据头无效"
        case .unsupportedVersion: "投屏协议版本不兼容"
        case .payloadTooLarge: "投屏数据超过安全上限"
        case .invalidSecret: "投屏配对密钥无效，请重新配对"
        case .decryptionFailed: "投屏数据校验失败"
        }
    }
}

public struct ScreenCastHeader: Sendable, Equatable {
    public let type: ScreenCastMessageType
    public let flags: ScreenCastPacketFlags
    public let payloadLength: Int
    public let sequence: UInt64
    public let presentationTimeUs: UInt64

    public init(
        type: ScreenCastMessageType,
        flags: ScreenCastPacketFlags,
        payloadLength: Int,
        sequence: UInt64,
        presentationTimeUs: UInt64
    ) {
        self.type = type
        self.flags = flags
        self.payloadLength = payloadLength
        self.sequence = sequence
        self.presentationTimeUs = presentationTimeUs
    }

    public func encoded() throws -> Data {
        guard flags.rawValue & ~UInt8(0b111) == 0 else {
            throw ScreenCastProtocolError.invalidHeader
        }
        let encryptionOverhead = flags.contains(.encrypted) ? 28 : 0
        let payloadLimit = type == .videoFrame
            ? screenCastMediaPayloadLimit + encryptionOverhead
            : screenCastControlPayloadLimit + encryptionOverhead
        guard payloadLength >= 0,
              payloadLength <= payloadLimit else {
            throw ScreenCastProtocolError.payloadTooLarge
        }
        var data = Data("HMCS".utf8)
        data.append(contentsOf: [0, 3, type.rawValue, flags.rawValue])
        data.appendInteger(UInt16(screenCastHeaderLength))
        data.appendInteger(UInt16(0))
        data.appendInteger(UInt32(payloadLength))
        data.appendInteger(sequence)
        data.appendInteger(presentationTimeUs)
        return data
    }

    public static func decode(_ data: Data) throws -> ScreenCastHeader {
        guard data.count >= screenCastHeaderLength,
              data.prefix(4) == Data("HMCS".utf8),
              data[4] == 0,
              data[5] == 3,
              let type = ScreenCastMessageType(rawValue: data[6]),
              data[7] & ~UInt8(0b111) == 0,
              data.readInteger(UInt16.self, at: 8) == UInt16(screenCastHeaderLength),
              data.readInteger(UInt16.self, at: 10) == 0 else {
            throw ScreenCastProtocolError.invalidHeader
        }
        guard let payloadLength = data.readInteger(UInt32.self, at: 12),
              let sequence = data.readInteger(UInt64.self, at: 16),
              let presentationTimeUs = data.readInteger(UInt64.self, at: 24) else {
            throw ScreenCastProtocolError.invalidHeader
        }
        let encryptedOverhead = data[7] & ScreenCastPacketFlags.encrypted.rawValue == 0 ? 0 : 28
        let limit = type == .videoFrame
            ? screenCastMediaPayloadLimit + encryptedOverhead
            : screenCastControlPayloadLimit + encryptedOverhead
        guard payloadLength <= UInt32(limit) else { throw ScreenCastProtocolError.payloadTooLarge }
        return ScreenCastHeader(
            type: type,
            flags: ScreenCastPacketFlags(rawValue: data[7]),
            payloadLength: Int(payloadLength),
            sequence: sequence,
            presentationTimeUs: presentationTimeUs
        )
    }
}

public struct ScreenCastHello: Codable, Sendable {
    public let app: String
    public let `protocol`: String
    public let deviceId: String
    public let deviceName: String
    public let identityFingerprint: String
    public let sessionId: String
    public let codec: String
    public let width: Int
    public let height: Int
    public let frameRate: Int
}

public struct ScreenCastAck: Codable, Sendable {
    public let accepted: Bool
    public let sessionId: String
    public let reason: String?

    public init(accepted: Bool, sessionId: String, reason: String? = nil) {
        self.accepted = accepted
        self.sessionId = sessionId
        self.reason = reason
    }
}

public struct ScreenCastVideoConfig: Codable, Sendable {
    public let codec: String
    public let width: Int
    public let height: Int
    public let frameRate: Int
}

public struct ScreenCastStreamControl: Codable, Sendable {
    public let command: String

    public init(command: String) { self.command = command }
}

public struct ScreenCastEnd: Codable, Sendable {
    public let reason: String
}

public struct ScreenCastPacket: Sendable {
    public let header: ScreenCastHeader
    public let headerData: Data
    public let payload: Data
}

/// TCP 可能任意拆分或合并消息；解析器只保留尚未组成完整 HMCS 帧的尾部数据。
public struct ScreenCastPacketParser: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) throws -> [ScreenCastPacket] {
        buffer.append(data)
        var packets: [ScreenCastPacket] = []
        while buffer.count >= screenCastHeaderLength {
            let headerData = Data(buffer.prefix(screenCastHeaderLength))
            let header = try ScreenCastHeader.decode(headerData)
            let totalLength = screenCastHeaderLength + header.payloadLength
            guard buffer.count >= totalLength else { break }
            let payloadStart = buffer.index(buffer.startIndex, offsetBy: screenCastHeaderLength)
            let payloadEnd = buffer.index(buffer.startIndex, offsetBy: totalLength)
            packets.append(ScreenCastPacket(
                header: header,
                headerData: headerData,
                payload: Data(buffer[payloadStart..<payloadEnd])
            ))
            // Data.removeFirst 会保留非零 startIndex；重建尾部可避免下一帧按整数下标访问时越界。
            buffer = Data(buffer.suffix(from: payloadEnd))
        }
        return packets
    }
}

public struct ScreenCastCipher: Sendable {
    private let key: SymmetricKey

    public init(sharedSecret: String) throws {
        guard let keyData = Data(hexEncoded: sharedSecret), keyData.count == 32 else {
            throw ScreenCastProtocolError.invalidSecret
        }
        key = SymmetricKey(data: keyData)
    }

    public func encrypt(_ data: Data, authenticating header: Data) throws -> Data {
        let box = try AES.GCM.seal(data, using: key, authenticating: header)
        guard let combined = box.combined else { throw ScreenCastProtocolError.decryptionFailed }
        return combined
    }

    public func decrypt(_ data: Data, authenticating header: Data) throws -> Data {
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: header)
        } catch {
            throw ScreenCastProtocolError.decryptionFailed
        }
    }
}

public func encodeScreenCastJSON<T: Encodable>(_ value: T) throws -> Data {
    try JSONEncoder().encode(value)
}

public func decodeScreenCastJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    try JSONDecoder().decode(type, from: data)
}

private extension Data {
    init?(hexEncoded text: String) {
        guard text.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    func readInteger<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T? {
        guard offset >= 0, count >= offset + MemoryLayout<T>.size else { return nil }
        return withUnsafeBytes { rawBuffer in
            let value = rawBuffer.loadUnaligned(fromByteOffset: offset, as: T.self)
            return T(bigEndian: value)
        }
    }
}
