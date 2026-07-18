import Foundation
import Testing
@testable import HMTransCore

@Test("HMCS 数据头按大端序保留类型、序号和时间戳")
func screenCastHeaderRoundTrip() throws {
    let header = ScreenCastHeader(
        type: .videoFrame,
        flags: [.encrypted, .keyFrame],
        payloadLength: 4_096,
        sequence: 42,
        presentationTimeUs: 9_000
    )
    let decoded = try ScreenCastHeader.decode(header.encoded())
    #expect(decoded == header)
}

@Test("HMCS 解析器可处理拆包与多个帧粘包")
func screenCastParserHandlesTCPFraming() throws {
    let firstPayload = Data("first".utf8)
    let secondPayload = Data("second".utf8)
    let firstHeader = ScreenCastHeader(
        type: .heartbeat,
        flags: [],
        payloadLength: firstPayload.count,
        sequence: 1,
        presentationTimeUs: 0
    )
    let secondHeader = ScreenCastHeader(
        type: .videoConfig,
        flags: [.encrypted],
        payloadLength: secondPayload.count,
        sequence: 2,
        presentationTimeUs: 0
    )
    let wire = try firstHeader.encoded() + firstPayload + secondHeader.encoded() + secondPayload
    var parser = ScreenCastPacketParser()
    #expect(try parser.append(Data(wire.prefix(17))).isEmpty)
    let packets = try parser.append(Data(wire.dropFirst(17)))
    #expect(packets.count == 2)
    #expect(packets[0].payload == firstPayload)
    #expect(packets[1].payload == secondPayload)
}

@Test("HMCS AES-GCM 会拒绝被篡改的帧头")
func screenCastCipherAuthenticatesHeader() throws {
    let cipher = try ScreenCastCipher(
        sharedSecret: String(repeating: "11", count: 32),
        sessionID: "session-1"
    )
    let plain = Data("screen-frame".utf8)
    let header = try ScreenCastHeader(
        type: .videoFrame,
        flags: [.encrypted],
        payloadLength: plain.count + 28,
        sequence: 7,
        presentationTimeUs: 100
    ).encoded()
    let sealed = try cipher.encrypt(plain, authenticating: header)
    #expect(try cipher.decrypt(sealed, authenticating: header) == plain)

    var modifiedHeader = header
    modifiedHeader[31] ^= 1
    #expect(throws: ScreenCastProtocolError.self) {
        try cipher.decrypt(sealed, authenticating: modifiedHeader)
    }
}

@Test("HMCS 拒绝未知标志位和非零保留字段")
func screenCastHeaderRejectsUnknownFields() throws {
    let valid = try ScreenCastHeader(
        type: .heartbeat,
        flags: [],
        payloadLength: 0,
        sequence: 1,
        presentationTimeUs: 0
    ).encoded()

    var unknownFlags = valid
    unknownFlags[7] = 1 << 7
    #expect(throws: ScreenCastProtocolError.self) {
        try ScreenCastHeader.decode(unknownFlags)
    }

    var nonzeroReserved = valid
    nonzeroReserved[11] = 1
    #expect(throws: ScreenCastProtocolError.self) {
        try ScreenCastHeader.decode(nonzeroReserved)
    }
}

@Test("HMCS 在读取载荷前拒绝超过上限的长度")
func screenCastHeaderRejectsOversizedPayload() throws {
    var wire = try ScreenCastHeader(
        type: .heartbeat,
        flags: [],
        payloadLength: 0,
        sequence: 1,
        presentationTimeUs: 0
    ).encoded()
    let oversized = UInt32(screenCastControlPayloadLimit + 1).bigEndian
    withUnsafeBytes(of: oversized) { bytes in
        wire.replaceSubrange(12..<16, with: bytes)
    }
    #expect(throws: ScreenCastProtocolError.self) {
        try ScreenCastHeader.decode(wire)
    }
}

@Test("Mac 主动投屏请求使用稳定规范文本和配对密钥 HMAC")
func screenCastStartRequestAuthenticationVector() throws {
    let request = ScreenCastStartRequest(
        requesterDeviceId: "mac-id",
        requesterFingerprint: "mac-fingerprint",
        targetDeviceId: "pad-id",
        requestId: "request-1",
        issuedAt: 1_721_217_600_000,
        signature: ""
    )
    #expect(
        request.canonicalAuthenticationText ==
            "screen_cast_start_request|HMTrans|0.2.0|mac-id|mac-fingerprint|pad-id|request-1|1721217600000"
    )
    let secret = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    #expect(
        try screenCastControlSignature(
            sharedSecret: secret,
            canonicalText: request.canonicalAuthenticationText
        ) == "b1829a62340f4e27c2ce5cc9b70b938e33280af12ad3621d8d3c00c2c2f40b78"
    )
}

@Test("投屏媒体密钥按 TCP 连接隔离并拒绝重连重放")
func screenCastMediaKeyIsConnectionScoped() throws {
    let secret = String(repeating: "22", count: 32)
    let first = try ScreenCastCipher(sharedSecret: secret, sessionID: "session|connection-a")
    let second = try ScreenCastCipher(sharedSecret: secret, sessionID: "session|connection-b")
    let payload = Data("frame".utf8)
    let header = try ScreenCastHeader(
        type: .videoFrame,
        flags: [.encrypted],
        payloadLength: payload.count + 28,
        sequence: 1,
        presentationTimeUs: 1
    ).encoded()
    let sealed = try first.encrypt(payload, authenticating: header)
    #expect(throws: ScreenCastProtocolError.self) {
        try second.decrypt(sealed, authenticating: header)
    }
}

@Test("主动投屏控制请求拒绝缺失或畸形配对密钥")
func screenCastStartRequestRejectsInvalidSecret() {
    #expect(throws: HMTransError.self) {
        try screenCastControlSignature(sharedSecret: "1234", canonicalText: "request")
    }
}

@Test("投屏网络测试数据使用媒体载荷上限并保持独立消息类型")
func screenCastNetworkTestUsesMediaPayloadLimit() throws {
    let header = ScreenCastHeader(
        type: .networkTestData,
        flags: [.encrypted],
        payloadLength: 256 * 1_024 + 28,
        sequence: 9,
        presentationTimeUs: 0
    )
    #expect(try ScreenCastHeader.decode(header.encoded()) == header)

    #expect(throws: ScreenCastProtocolError.self) {
        try ScreenCastHeader(
            type: .networkTestPing,
            flags: [.encrypted],
            payloadLength: screenCastControlPayloadLimit + 29,
            sequence: 10,
            presentationTimeUs: 0
        ).encoded()
    }
}

@Test("投屏网络测试结果可跨端 JSON 往返")
func screenCastNetworkTestResultRoundTrip() throws {
    let expected = ScreenCastNetworkTestResult(
        sessionId: "test-session",
        receivedBytes: 32 * 1_024 * 1_024,
        durationMs: 2_000,
        throughputMbps: 134.2,
        averageRttMs: 3.4,
        jitterMs: 0.8,
        recommendation: "双路 1080P60"
    )
    let encoded = try encodeScreenCastJSON(expected)
    #expect(try decodeScreenCastJSON(ScreenCastNetworkTestResult.self, from: encoded) == expected)
}

@Test("双路投屏只放行两台不同设备的 1080P30 会话")
func screenCastAdmissionPolicyEnforcesMultiStreamBudget() {
    let first = testHello(deviceID: "pad-a", sessionID: "session-a", width: 1_920, height: 1_260, fps: 30)
    let second = testHello(deviceID: "pad-b", sessionID: "session-b", width: 1_920, height: 1_260, fps: 30)
    #expect(ScreenCastAdmissionPolicy.rejectionReason(existing: [], candidate: first) == nil)
    #expect(ScreenCastAdmissionPolicy.rejectionReason(existing: [first], candidate: second) == nil)

    let third = testHello(deviceID: "pad-c", sessionID: "session-c", width: 1_280, height: 840, fps: 30)
    #expect(ScreenCastAdmissionPolicy.rejectionReason(existing: [first, second], candidate: third) ==
        "Mac 已达到两路投屏上限")

    let duplicate = testHello(deviceID: "pad-a", sessionID: "session-new", width: 1_280, height: 840, fps: 30)
    #expect(ScreenCastAdmissionPolicy.rejectionReason(existing: [first], candidate: duplicate) ==
        "该设备已有投屏会话")

    let highFrameRate = testHello(deviceID: "pad-b", sessionID: "session-fast", width: 1_920, height: 1_260, fps: 60)
    #expect(ScreenCastAdmissionPolicy.rejectionReason(existing: [first], candidate: highFrameRate) ==
        "多路投屏需要所有设备使用 1080P 级 / 30P")
}

private func testHello(
    deviceID: String,
    sessionID: String,
    width: Int,
    height: Int,
    fps: Int
) -> ScreenCastHello {
    ScreenCastHello(
        app: "HMTrans",
        protocol: screenCastProtocolVersion,
        deviceId: deviceID,
        deviceName: deviceID,
        identityFingerprint: "fingerprint-\(deviceID)",
        sessionId: sessionID,
        connectionId: "connection-\(sessionID)",
        codec: "h264-annexb",
        width: width,
        height: height,
        frameRate: fps
    )
}
