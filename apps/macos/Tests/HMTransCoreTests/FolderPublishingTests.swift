import Foundation
import Testing
@testable import HMTransCore

@Test("嵌套文件夹归档校验后还原为同名文件夹")
func nestedFolderPublishesAfterValidation() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("HMTransFolderTest-\(UUID().uuidString)", isDirectory: true)
    let source = root.appendingPathComponent("设计素材", isDirectory: true)
    let nested = source.appendingPathComponent("第一层/第二层", isDirectory: true)
    let output = root.appendingPathComponent("output", isDirectory: true)
    let staging = root.appendingPathComponent("staging", isDirectory: true)
    try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }

    let expected = Data("HMTrans nested folder".utf8)
    try expected.write(to: nested.appendingPathComponent("原文件.txt"))
    let archive = staging.appendingPathComponent("payload.zip")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-c", "-k", "--keepParent", source.path, archive.path]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)

    let meta = FileMeta(
        transferId: UUID().uuidString,
        fileName: "payload.zip",
        fileSize: Int64((try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
        sha256: "not-used-after-wire-verification",
        totalChunks: 1,
        sourceKind: "folder",
        payloadKind: "zip",
        sourceName: "设计素材",
        sourceSize: Int64(expected.count),
        sourceFileCount: 1
    )
    let published = try publishReceivedPayload(
        meta: meta,
        payloadURL: archive,
        defaultDestination: output.appendingPathComponent("payload.zip"),
        outputDirectory: output,
        stagingRoot: staging
    )

    #expect(published.lastPathComponent == "设计素材")
    #expect(try Data(contentsOf: published.appendingPathComponent("第一层/第二层/原文件.txt")) == expected)
    #expect(!fileManager.fileExists(atPath: archive.path))
}
