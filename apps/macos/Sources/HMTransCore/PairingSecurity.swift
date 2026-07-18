import CryptoKit
import Foundation

public let hmTransSecurityVersion = 1

/// 接收端批准一次配对时返回当前仍有效的六位码；只有握手证明通过后才落盘长期密钥。
public struct PairingAuthorization: @unchecked Sendable {
    public let code: String
    private let establishmentHandler: @Sendable (String) -> Void

    public init(code: String, onEstablished: @escaping @Sendable (String) -> Void) {
        self.code = code.filter(\.isNumber)
        self.establishmentHandler = onEstablished
    }

    func establish(sharedSecret: String) {
        establishmentHandler(sharedSecret)
    }
}

public struct PairingOutcome: Sendable {
    public let response: PairingResponse
    /// X25519 协商并经六位码认证后派生的 256 位主密钥；它从不出现在网络消息中。
    public let sharedSecret: String?

    public init(response: PairingResponse, sharedSecret: String?) {
        self.response = response
        self.sharedSecret = sharedSecret
    }
}

struct PairingInitiatorState: Sendable {
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    let code: String
    let request: PairingRequest

    init(
        requesterDeviceId: String,
        requesterName: String,
        requesterPlatform: String,
        requesterSystemVersion: String,
        requesterIP: String,
        requesterPort: UInt16,
        requesterFingerprint: String,
        targetDeviceId: String,
        targetFingerprint: String,
        code: String
    ) throws {
        let normalizedCode = code.filter(\.isNumber)
        guard normalizedCode.count == 6 else {
            throw HMTransError.usage("请输入六位配对码")
        }
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let requestID = UUID().uuidString.lowercased()
        self.privateKey = privateKey
        self.code = normalizedCode
        request = PairingRequest(
            requesterDeviceId: requesterDeviceId,
            requesterName: requesterName,
            requesterPlatform: requesterPlatform,
            requesterSystemVersion: requesterSystemVersion,
            requesterIP: requesterIP,
            requesterPort: requesterPort,
            requesterFingerprint: requesterFingerprint,
            targetDeviceId: targetDeviceId,
            targetFingerprint: targetFingerprint,
            requestId: requestID,
            requesterPublicKey: privateKey.publicKey.derRepresentation.base64EncodedString()
        )
    }

    func answer(_ challenge: PairingChallenge) throws -> (PairingConfirmation, String) {
        guard challenge.accepted,
              challenge.requestId == request.requestId,
              challenge.securityVersion == hmTransSecurityVersion,
              let encodedKey = Data(base64Encoded: challenge.responderPublicKey),
              let rawKey = encodedKey.x25519RawPublicKey
        else {
            throw HMTransError.rejected(challenge.reason ?? "配对握手被拒绝")
        }
        let responder = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: rawKey)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: responder)
        let transcript = request.authenticationTranscript(responderPublicKey: challenge.responderPublicKey)
        let keys = PairingDerivedKeys(sharedSecret: secret, code: code, transcript: transcript)
        guard secureDataEquals(
            Data(hexEncodedPairing: challenge.proof),
            hmacSHA256(key: keys.authenticationKey, text: "responder|\(transcript)")
        ) else {
            throw HMTransError.rejected("配对码错误或握手身份不匹配")
        }
        return (
            PairingConfirmation(
                requestId: request.requestId,
                proof: hmacSHA256(key: keys.authenticationKey, text: "requester|\(transcript)").hexString
            ),
            keys.masterKey.withUnsafeBytes { Data($0).hexString }
        )
    }
}

struct PairingResponderState: Sendable {
    let challenge: PairingChallenge
    let masterSecret: String
    private let expectedConfirmation: Data

    init(request: PairingRequest, code: String) throws {
        let normalizedCode = code.filter(\.isNumber)
        guard normalizedCode.count == 6,
              request.securityVersion == hmTransSecurityVersion,
              let encodedKey = Data(base64Encoded: request.requesterPublicKey),
              let rawKey = encodedKey.x25519RawPublicKey
        else {
            throw HMTransError.protocolError("无效安全配对请求")
        }
        let requester = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: rawKey)
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let responderPublicKey = privateKey.publicKey.derRepresentation.base64EncodedString()
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: requester)
        let transcript = request.authenticationTranscript(responderPublicKey: responderPublicKey)
        let keys = PairingDerivedKeys(sharedSecret: secret, code: normalizedCode, transcript: transcript)
        challenge = PairingChallenge(
            accepted: true,
            requestId: request.requestId,
            responderPublicKey: responderPublicKey,
            proof: hmacSHA256(key: keys.authenticationKey, text: "responder|\(transcript)").hexString,
            securityVersion: hmTransSecurityVersion
        )
        expectedConfirmation = hmacSHA256(key: keys.authenticationKey, text: "requester|\(transcript)")
        masterSecret = keys.masterKey.withUnsafeBytes { Data($0).hexString }
    }

    func accepts(_ confirmation: PairingConfirmation) -> Bool {
        confirmation.requestId == challenge.requestId
            && secureDataEquals(Data(hexEncodedPairing: confirmation.proof), expectedConfirmation)
    }
}

private struct PairingDerivedKeys {
    let authenticationKey: SymmetricKey
    let masterKey: SymmetricKey

    init(sharedSecret: SharedSecret, code: String, transcript: String) {
        let salt = Data(SHA256.hash(data: Data("HMTrans|pairing-code|\(code)".utf8)))
        authenticationKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("HMTrans|pairing-auth-v1|\(transcript)".utf8),
            outputByteCount: 32
        )
        let authenticationData = authenticationKey.withUnsafeBytes { Data($0) }
        masterKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedSecret.withUnsafeBytes { Data($0) }),
            salt: authenticationData,
            info: Data("HMTrans|master-secret-v1|\(transcript)".utf8),
            outputByteCount: 32
        )
    }
}

/// 从配对主密钥派生用途隔离子密钥，避免文件认证、控制认证和媒体加密共用原始密钥。
public func hmTransDerivedKey(sharedSecret: String, purpose: String, context: String = "") throws -> SymmetricKey {
    guard let master = Data(hexEncodedPairing: sharedSecret), master.count == 32 else {
        throw HMTransError.protocolError("该配对缺少安全密钥，请删除设备后重新配对")
    }
    return HKDF<SHA256>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: master),
        salt: Data("HMTrans|security-v1".utf8),
        info: Data("HMTrans|\(purpose)|\(context)".utf8),
        outputByteCount: 32
    )
}

public func hmTransAuthenticationCode(
    sharedSecret: String,
    purpose: String,
    canonicalText: String,
    context: String = ""
) throws -> String {
    let key = try hmTransDerivedKey(sharedSecret: sharedSecret, purpose: purpose, context: context)
    return hmacSHA256(key: key, text: canonicalText).hexString
}

public func hmTransSecureHexEquals(_ lhs: String, _ rhs: String) -> Bool {
    secureDataEquals(Data(hexEncodedPairing: lhs), Data(hexEncodedPairing: rhs))
}

public func authenticatedFileMeta(_ meta: FileMeta, sharedSecret: String) throws -> FileMeta {
    let authenticationID = UUID().uuidString.lowercased()
    let issuedAt = Int64(Date().timeIntervalSince1970 * 1_000)
    let unsigned = FileMeta(
        type: meta.type, app: meta.app, version: meta.version, transferId: meta.transferId,
        senderDeviceId: meta.senderDeviceId, senderName: meta.senderName,
        senderPlatform: meta.senderPlatform, fileName: meta.fileName, fileSize: meta.fileSize,
        sha256: meta.sha256, chunkSize: meta.chunkSize, totalChunks: meta.totalChunks,
        resumeSupported: meta.resumeSupported, sourceKind: meta.sourceKind, payloadKind: meta.payloadKind,
        sourceName: meta.sourceName, sourceSize: meta.sourceSize, sourceFileCount: meta.sourceFileCount,
        senderFingerprint: meta.senderFingerprint, authenticationVersion: hmTransSecurityVersion,
        authenticationId: authenticationID, issuedAt: issuedAt, signature: ""
    )
    let signature = try hmTransAuthenticationCode(
        sharedSecret: sharedSecret,
        purpose: "file-transfer-auth-v1",
        canonicalText: unsigned.canonicalAuthenticationText
    )
    return FileMeta(
        type: unsigned.type, app: unsigned.app, version: unsigned.version, transferId: unsigned.transferId,
        senderDeviceId: unsigned.senderDeviceId, senderName: unsigned.senderName,
        senderPlatform: unsigned.senderPlatform, fileName: unsigned.fileName, fileSize: unsigned.fileSize,
        sha256: unsigned.sha256, chunkSize: unsigned.chunkSize, totalChunks: unsigned.totalChunks,
        resumeSupported: unsigned.resumeSupported, sourceKind: unsigned.sourceKind, payloadKind: unsigned.payloadKind,
        sourceName: unsigned.sourceName, sourceSize: unsigned.sourceSize, sourceFileCount: unsigned.sourceFileCount,
        senderFingerprint: unsigned.senderFingerprint, authenticationVersion: unsigned.authenticationVersion,
        authenticationId: unsigned.authenticationId, issuedAt: unsigned.issuedAt, signature: signature
    )
}

public func verifyFileMetaAuthentication(
    _ meta: FileMeta,
    sharedSecret: String,
    nowMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
    allowedClockSkewMilliseconds: Int64 = 5 * 60 * 1_000
) -> Bool {
    guard meta.authenticationVersion == hmTransSecurityVersion,
          meta.authenticationId?.isEmpty == false,
          let issuedAt = meta.issuedAt,
          abs(nowMilliseconds - issuedAt) <= allowedClockSkewMilliseconds,
          let signature = meta.signature,
          let expected = try? hmTransAuthenticationCode(
              sharedSecret: sharedSecret,
              purpose: "file-transfer-auth-v1",
              canonicalText: meta.canonicalAuthenticationText
          )
    else { return false }
    return hmTransSecureHexEquals(signature, expected)
}

private func hmacSHA256(key: SymmetricKey, text: String) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key))
}

private func secureDataEquals(_ lhs: Data?, _ rhs: Data?) -> Bool {
    guard let lhs, let rhs, !lhs.isEmpty, lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
}

private extension Curve25519.KeyAgreement.PublicKey {
    /// SubjectPublicKeyInfo DER for id-X25519 (RFC 8410). HarmonyOS exposes the same X.509 form.
    var derRepresentation: Data {
        Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x03, 0x21, 0x00])
            + rawRepresentation
    }
}

private extension Data {
    var x25519RawPublicKey: Data? {
        let prefix = Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x03, 0x21, 0x00])
        guard count == prefix.count + 32, starts(with: prefix) else { return nil }
        return suffix(32)
    }

    init?(hexEncodedPairing text: String) {
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

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
