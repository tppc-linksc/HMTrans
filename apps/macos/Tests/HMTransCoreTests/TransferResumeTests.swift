import Foundation
import Testing
@testable import HMTransCore

private final class OffsetBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0

    func record(_ offset: Int64) {
        lock.lock()
        value = max(value, offset)
        lock.unlock()
    }

    func load() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class ReceivedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ReceivedFile?

    func record(_ file: ReceivedFile?) {
        guard let file else { return }
        lock.lock(); value = file; lock.unlock()
    }

    func load() -> ReceivedFile? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

@Test("断线后使用同一任务 ID 从私有分片继续")
func interruptedTransferResumes() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("HMTransResumeTest-\(UUID().uuidString)", isDirectory: true)
    let inputDirectory = root.appendingPathComponent("input", isDirectory: true)
    let outputDirectory = root.appendingPathComponent("output", isDirectory: true)
    try fileManager.createDirectory(at: inputDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }

    let sourceURL = inputDirectory.appendingPathComponent("resume.bin")
    let sourceData = Data(repeating: 0x5A, count: 8 * 1_048_576)
    try sourceData.write(to: sourceURL)

    let transferID = "resume-test-\(UUID().uuidString)"
    let port = UInt16.random(in: 52_000...59_000)
    let receiver = PersistentFileReceiver()
    let receivedBox = ReceivedBox()
    try receiver.start(port: port, outputDirectory: outputDirectory.path, shouldAccept: { _ in true }) { result in
        if case .success(let file) = result { receivedBox.record(file) }
    }
    defer { receiver.stop() }
    try await Task.sleep(for: .milliseconds(500))

    let control = TransferControl()
    let firstSender = Task.detached { () -> Result<Void, Error> in
        Result {
            try sendFile(
                fileURL: sourceURL,
                host: "127.0.0.1",
                port: port,
                transferId: transferID,
                control: control
            ) { current, _ in
                if current >= 2 * 1_048_576 {
                    control.cancel()
                }
            }
        }
    }
    let firstSendResult = await firstSender.value
    #expect(firstSendResult.isFailure)
    try await Task.sleep(for: .milliseconds(100))

    let resumedOffset = OffsetBox()
    try sendFile(
        fileURL: sourceURL,
        host: "127.0.0.1",
        port: port,
        transferId: transferID
    ) { current, _ in
        resumedOffset.record(current)
    }
    for _ in 0..<100 where receivedBox.load() == nil {
        try await Task.sleep(for: .milliseconds(50))
    }
    let receivedURL = try #require(receivedBox.load()?.url)

    #expect(resumedOffset.load() > 0)
    #expect(try Data(contentsOf: receivedURL) == sourceData)
}

private extension Result {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}
