import Foundation
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
        onPairingRequest: { $0.code == "246810" && $0.requesterFingerprint == "fingerprint" },
        shouldAccept: { _ in false },
        onConnectionResult: { _ in }
    )
    defer { receiver.stop() }
    try await Task.sleep(for: .milliseconds(250))

    let rejected = try requestPairing(
        host: "127.0.0.1", port: port, requesterDeviceId: "pad", requesterName: "MatePad",
        requesterPlatform: "HarmonyOS", requesterSystemVersion: "6.1", requesterIP: "127.0.0.1",
        requesterPort: 51888, code: "000000", requesterFingerprint: "fingerprint"
    )
    let accepted = try requestPairing(
        host: "127.0.0.1", port: port, requesterDeviceId: "pad", requesterName: "MatePad",
        requesterPlatform: "HarmonyOS", requesterSystemVersion: "6.1", requesterIP: "127.0.0.1",
        requesterPort: 51888, code: "246 810", requesterFingerprint: "fingerprint"
    )
    #expect(!rejected.accepted)
    #expect(accepted.accepted)
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
