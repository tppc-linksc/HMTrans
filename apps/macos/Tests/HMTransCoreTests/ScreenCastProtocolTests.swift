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
    let cipher = try ScreenCastCipher(sharedSecret: String(repeating: "11", count: 32))
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
