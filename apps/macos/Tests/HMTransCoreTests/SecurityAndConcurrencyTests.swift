import Foundation
import Network
import Testing
@testable import HMTransCore

private final class ReceivedURLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func append(_ file: ReceivedFile?) {
        guard let file else { return }
        lock.lock(); urls.append(file.url); lock.unlock()
    }

    func first() -> URL? {
        lock.lock(); defer { lock.unlock() }
        return urls.first
    }
}

private final class StalledConnectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [NWConnection] = []

    func retain(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
    }

    func cancelAll() {
        lock.withLock {
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }
}

private final class ListenerReadyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false

    var isReady: Bool { lock.withLock { ready } }
    func markReady() { lock.withLock { ready = true } }
}

private final class ReceiveErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Error?

    func store(_ error: Error) { lock.withLock { value = error } }
    func load() -> Error? { lock.withLock { value } }
}

@Test("诊断信息会脱敏所有本地磁盘路径并保留网页地址")
func diagnosticRedactionCoversMacVolumes() {
    let source = "来源 /Volumes/Work/private.mov，缓存 /System/Volumes/Data/tmp/a.bin，主页 ~/Downloads/a.zip，帮助 https://hmt.tppc.top/privacy.html，设备 192.168.3.204"
    let redacted = redactDiagnosticTextForSharing(source)
    #expect(!redacted.contains("/Volumes/"))
    #expect(!redacted.contains("/System/"))
    #expect(!redacted.contains("~/Downloads"))
    #expect(redacted.contains("https://hmt.tppc.top/privacy.html"))
    #expect(redacted.contains("<local-ip>"))
}

@Test("对端半开时网络读取会超时而不是永久阻塞")
func stalledPeerTimesOut() async throws {
    let queue = DispatchQueue(label: "HMTransTests.StalledPeer")
    let listener = try NWListener(using: .tcp, on: .any)
    let connections = StalledConnectionBox()
    let listenerReady = ListenerReadyBox()
    listener.stateUpdateHandler = { state in
        if case .ready = state { listenerReady.markReady() }
    }
    listener.newConnectionHandler = { connection in
        connections.retain(connection)
        connection.start(queue: queue)
        // 故意不读取也不回复，用来模拟保持连接却永远不返回接收决策帧的 TCP 对端。
    }
    listener.start(queue: queue)
    defer {
        listener.cancel()
        connections.cancelAll()
    }

    for _ in 0..<50 where !listenerReady.isReady {
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(listenerReady.isReady)
    let port = try #require(listener.port?.rawValue)
    let source = FileManager.default.temporaryDirectory
        .appendingPathComponent("HMTransTimeout-\(UUID()).bin")
    try Data("timeout".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }

    let started = ContinuousClock.now
    #expect(throws: HMTransError.self) {
        try sendFile(
            fileURL: source,
            host: "127.0.0.1",
            port: port,
            networkTimeout: 0.2
        )
    }
    #expect(started.duration(to: .now) < .seconds(2))
}

@Test("慢速未完成控制消息不会阻塞后续配对连接")
func stalledControlLineDoesNotBlockAnotherConnection() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("HMTransConcurrentReceiver-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let port = UInt16.random(in: 35_000...39_000)
    let receiver = PersistentFileReceiver()
    try receiver.start(
        port: port,
        outputDirectory: root.path,
        onPairingRequest: { request in
            guard request.targetDeviceId == "mac", request.targetFingerprint == "mac-fingerprint" else { return nil }
            return PairingAuthorization(code: "246810") { _ in }
        },
        shouldAccept: { _ in false },
        onConnectionResult: { _ in }
    )
    defer { receiver.stop() }
    try await Task.sleep(for: .milliseconds(250))

    let stalled = NWConnection(
        host: NWEndpoint.Host("127.0.0.1"),
        port: try #require(NWEndpoint.Port(rawValue: port)),
        using: .tcp
    )
    let stalledReady = ListenerReadyBox()
    let stalledQueue = DispatchQueue(label: "HMTransTests.StalledControlLine")
    stalled.stateUpdateHandler = { state in
        guard case .ready = state else { return }
        stalled.send(content: Data("{".utf8), completion: .contentProcessed { _ in
            stalledReady.markReady()
        })
    }
    stalled.start(queue: stalledQueue)
    defer { stalled.cancel() }
    for _ in 0..<50 where !stalledReady.isReady {
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(stalledReady.isReady)

    let started = ContinuousClock.now
    let response = try requestPairing(
        host: "127.0.0.1",
        port: port,
        requesterDeviceId: "pad",
        requesterName: "MatePad",
        requesterPlatform: "HarmonyOS",
        requesterSystemVersion: "6.1",
        requesterIP: "127.0.0.1",
        requesterPort: 51888,
        code: "246810",
        requesterFingerprint: "fingerprint",
        targetDeviceId: "mac",
        targetFingerprint: "mac-fingerprint",
        networkTimeout: 1
    )
    #expect(response.response.accepted)
    #expect(response.sharedSecret?.count == 64)
    #expect(started.duration(to: .now) < .seconds(2))
}

@Test("文件夹归档中的符号链接在解压前被拒绝")
func symbolicLinkArchiveIsRejected() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("HMTransUnsafeZip-\(UUID())", isDirectory: true)
    let source = root.appendingPathComponent("source", isDirectory: true)
    let output = root.appendingPathComponent("output", isDirectory: true)
    let staging = root.appendingPathComponent("staging", isDirectory: true)
    try manager.createDirectory(at: source, withIntermediateDirectories: true)
    try manager.createDirectory(at: output, withIntermediateDirectories: true)
    try manager.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }

    let outside = root.appendingPathComponent("outside.txt")
    try Data("outside".utf8).write(to: outside)
    try manager.createSymbolicLink(at: source.appendingPathComponent("escape"), withDestinationURL: outside)
    let archive = staging.appendingPathComponent("unsafe.zip")
    try runDitto(arguments: ["-c", "-k", "--keepParent", source.path, archive.path])
    let size = try #require(try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    let meta = FileMeta(
        transferId: UUID().uuidString,
        fileName: archive.lastPathComponent,
        fileSize: Int64(size),
        sha256: "verified-before-publish",
        totalChunks: 1,
        sourceKind: "folder",
        payloadKind: "zip",
        sourceName: "source"
    )

    #expect(throws: HMTransError.self) {
        _ = try publishReceivedPayload(
            meta: meta,
            payloadURL: archive,
            defaultDestination: output.appendingPathComponent("unsafe.zip"),
            outputDirectory: output,
            stagingRoot: staging
        )
    }
    #expect(try manager.contentsOfDirectory(atPath: output.path).isEmpty)
}

@Test("异常高压缩比归档在解压前被拒绝")
func compressionBombArchiveIsRejected() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("HMTransZipRatio-\(UUID())", isDirectory: true)
    let source = root.appendingPathComponent("source", isDirectory: true)
    try manager.createDirectory(at: source, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    try Data(repeating: 0, count: 20 * 1_048_576).write(to: source.appendingPathComponent("zeros.bin"))
    let archive = root.appendingPathComponent("ratio.zip")
    try runDitto(arguments: ["-c", "-k", "--keepParent", source.path, archive.path])

    #expect(throws: HMTransError.self) {
        _ = try ZipArchiveInspector.inspect(archive)
    }
}

@Test("接收连接中断会携带准确的线上任务 ID")
func interruptedReceiveReportsExactTransferID() async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("HMTransReceiveError-\(UUID())", isDirectory: true)
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let port = UInt16.random(in: 40_000...44_000)
    let transferID = UUID().uuidString
    let errorBox = ReceiveErrorBox()
    let receiver = PersistentFileReceiver()
    try receiver.start(port: port, outputDirectory: root.path, shouldAccept: { _ in true }) { result in
        if case .failure(let error) = result { errorBox.store(error) }
    }
    defer { receiver.stop() }
    try await Task.sleep(for: .milliseconds(250))

    let connection = NWConnection(
        host: NWEndpoint.Host("127.0.0.1"),
        port: try #require(NWEndpoint.Port(rawValue: port)),
        using: .tcp
    )
    let queue = DispatchQueue(label: "HMTransTests.InterruptedReceive")
    let meta = FileMeta(
        transferId: transferID,
        fileName: "partial.bin",
        fileSize: 1_048_576,
        sha256: String(repeating: "0", count: 64),
        totalChunks: 1
    )
    var encodedLine = try JSONEncoder().encode(meta)
    encodedLine.append(0x0A)
    let line = encodedLine
    connection.stateUpdateHandler = { state in
        guard case .ready = state else { return }
        connection.send(content: line, completion: .contentProcessed { _ in connection.cancel() })
    }
    connection.start(queue: queue)
    defer { connection.cancel() }

    for _ in 0..<100 where errorBox.load() == nil {
        try await Task.sleep(for: .milliseconds(25))
    }
    let receiveError = try #require(errorBox.load() as? ReceiveConnectionError)
    #expect(receiveError.transferID == transferID)
}

@Test("配对端只接受当前六位码")
func pairingRequiresCurrentCode() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("HMTransPairing-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let port = UInt16.random(in: 45_000...49_000)
    let receiver = PersistentFileReceiver()
    try receiver.start(
        port: port,
        outputDirectory: root.path,
        onPairingRequest: { request in
            guard request.requesterFingerprint == "fingerprint",
                  request.targetDeviceId == "mac", request.targetFingerprint == "mac-fingerprint"
            else { return nil }
            return PairingAuthorization(code: "246810") { _ in }
        },
        shouldAccept: { _ in false },
        onConnectionResult: { _ in }
    )
    defer { receiver.stop() }
    try await Task.sleep(for: .milliseconds(250))

    #expect(throws: HMTransError.self) {
        try requestPairing(
            host: "127.0.0.1", port: port, requesterDeviceId: "pad", requesterName: "MatePad",
            requesterPlatform: "HarmonyOS", requesterSystemVersion: "6.1", requesterIP: "127.0.0.1",
            requesterPort: 51888, code: "000000", requesterFingerprint: "fingerprint",
            targetDeviceId: "mac", targetFingerprint: "mac-fingerprint"
        )
    }
    let accepted = try requestPairing(
        host: "127.0.0.1", port: port, requesterDeviceId: "pad", requesterName: "MatePad",
        requesterPlatform: "HarmonyOS", requesterSystemVersion: "6.1", requesterIP: "127.0.0.1",
        requesterPort: 51888, code: "246 810", requesterFingerprint: "fingerprint",
        targetDeviceId: "mac", targetFingerprint: "mac-fingerprint"
    )
    #expect(accepted.response.accepted)
    #expect(accepted.sharedSecret?.count == 64)
}

@Test("解除配对只接受已验证身份发给本机的请求")
func unpairRequiresTrustedIdentityAndTarget() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("HMTransUnpair-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let port = UInt16.random(in: 49_001...52_000)
    let sharedSecret = String(repeating: "33", count: 32)
    let receiver = PersistentFileReceiver()
    try receiver.start(
        port: port,
        outputDirectory: root.path,
        onUnpairRequest: {
            guard $0.requesterDeviceId == "pad", $0.requesterFingerprint == "trusted-fingerprint",
                  $0.targetDeviceId == "mac",
                  let expected = try? hmTransAuthenticationCode(
                      sharedSecret: sharedSecret,
                      purpose: "unpair-control-auth-v1",
                      canonicalText: $0.canonicalAuthenticationText
                  )
            else { return false }
            return hmTransSecureHexEquals($0.signature, expected)
        },
        shouldAccept: { _ in false },
        onConnectionResult: { _ in }
    )
    defer { receiver.stop() }
    try await Task.sleep(for: .milliseconds(250))

    let rejected = try requestUnpair(
        host: "127.0.0.1", port: port, requesterDeviceId: "pad",
        requesterFingerprint: "wrong-fingerprint", targetDeviceId: "mac", sharedSecret: sharedSecret
    )
    let accepted = try requestUnpair(
        host: "127.0.0.1", port: port, requesterDeviceId: "pad",
        requesterFingerprint: "trusted-fingerprint", targetDeviceId: "mac", sharedSecret: sharedSecret
    )
    #expect(!rejected.accepted)
    #expect(accepted.accepted)
}

@Test("文件元数据认证绑定内容并使用独立用途密钥")
func fileMetaAuthenticationRejectsTampering() throws {
    let secret = String(repeating: "44", count: 32)
    let original = FileMeta(
        transferId: "transfer-1",
        senderDeviceId: "mac",
        fileName: "report.pdf",
        fileSize: 123,
        sha256: String(repeating: "a", count: 64),
        totalChunks: 1,
        senderFingerprint: "fingerprint"
    )
    let signed = try authenticatedFileMeta(original, sharedSecret: secret)
    #expect(verifyFileMetaAuthentication(signed, sharedSecret: secret))
    let tampered = FileMeta(
        transferId: signed.transferId,
        senderDeviceId: signed.senderDeviceId,
        fileName: "changed.pdf",
        fileSize: signed.fileSize,
        sha256: signed.sha256,
        totalChunks: signed.totalChunks,
        senderFingerprint: signed.senderFingerprint,
        authenticationVersion: signed.authenticationVersion,
        authenticationId: signed.authenticationId,
        issuedAt: signed.issuedAt,
        signature: signed.signature
    )
    #expect(!verifyFileMetaAuthentication(tampered, sharedSecret: secret))
}

@Test("两个设备可同时接收不同文件且内容保持一致")
func twoDevicesReceiveDifferentFilesConcurrently() async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("HMTransMultiTarget-\(UUID())", isDirectory: true)
    let outputA = root.appendingPathComponent("a", isDirectory: true)
    let outputB = root.appendingPathComponent("b", isDirectory: true)
    try manager.createDirectory(at: outputA, withIntermediateDirectories: true)
    try manager.createDirectory(at: outputB, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let fileA = root.appendingPathComponent("alpha.bin")
    let fileB = root.appendingPathComponent("beta.bin")
    let dataA = Data(repeating: 0xA1, count: 2 * 1_048_576)
    let dataB = Data(repeating: 0xB2, count: 3 * 1_048_576)
    try dataA.write(to: fileA); try dataB.write(to: fileB)

    let portA = UInt16.random(in: 50_000...53_000)
    let portB = UInt16.random(in: 54_000...57_000)
    let receiverA = PersistentFileReceiver(); let receiverB = PersistentFileReceiver()
    let boxA = ReceivedURLBox(); let boxB = ReceivedURLBox()
    try receiverA.start(port: portA, outputDirectory: outputA.path, shouldAccept: { _ in true }) { result in
        if case .success(let file) = result { boxA.append(file) }
    }
    try receiverB.start(port: portB, outputDirectory: outputB.path, shouldAccept: { _ in true }) { result in
        if case .success(let file) = result { boxB.append(file) }
    }
    defer { receiverA.stop(); receiverB.stop() }
    try await Task.sleep(for: .milliseconds(300))

    async let sendA: Void = Task.detached { try sendFile(fileURL: fileA, host: "127.0.0.1", port: portA) }.value
    async let sendB: Void = Task.detached { try sendFile(fileURL: fileB, host: "127.0.0.1", port: portB) }.value
    _ = try await (sendA, sendB)
    for _ in 0..<80 where boxA.first() == nil || boxB.first() == nil {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(try Data(contentsOf: #require(boxA.first())) == dataA)
    #expect(try Data(contentsOf: #require(boxB.first())) == dataB)
}

private func runDitto(arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = arguments
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw HMTransError.system("ditto test fixture failed")
    }
}
