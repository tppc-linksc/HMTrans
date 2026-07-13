import Foundation

/// 原子发布已经校验的载荷；文件夹归档在所有路径通过校验并完成解压前始终留在私有目录。
func publishReceivedPayload(
    meta: FileMeta,
    payloadURL: URL,
    defaultDestination: URL,
    outputDirectory: URL,
    stagingRoot: URL
) throws -> URL {
    guard meta.sourceKind == "folder", meta.payloadKind == "zip" else {
        let destination = FileManager.default.fileExists(atPath: defaultDestination.path)
            ? uniqueDestinationURL(directory: outputDirectory, fileName: meta.fileName)
            : defaultDestination
        try FileManager.default.moveItem(at: payloadURL, to: destination)
        return destination
    }

    let archive = try ZipArchiveInspector.inspect(payloadURL)
    let fileSystem = try FileManager.default.attributesOfFileSystem(forPath: stagingRoot.path)
    let available = (fileSystem[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    let safetyMargin: Int64 = 64 * 1_024 * 1_024
    guard available >= archive.expandedSize + safetyMargin else {
        throw HMTransError.system("文件夹解压空间不足")
    }
    let unpackRoot = stagingRoot.appendingPathComponent("\(meta.transferId)-unpack", isDirectory: true)
    try? FileManager.default.removeItem(at: unpackRoot)
    try FileManager.default.createDirectory(at: unpackRoot, withIntermediateDirectories: true)
    do {
        try runPublishingProcess(
            executable: "/usr/bin/ditto",
            arguments: ["-x", "-k", payloadURL.path, unpackRoot.path]
        )
        let visibleChildren = try FileManager.default.contentsOfDirectory(
            at: unpackRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter { $0.lastPathComponent != "__MACOSX" }
        let sourceName = meta.sourceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let destination = uniqueDestinationURL(
            directory: outputDirectory,
            fileName: sourceName.isEmpty ? "接收的文件夹" : sourceName
        )
        if visibleChildren.count == 1,
           (try? visibleChildren[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            try FileManager.default.moveItem(at: visibleChildren[0], to: destination)
            try? FileManager.default.removeItem(at: unpackRoot)
        } else {
            try FileManager.default.moveItem(at: unpackRoot, to: destination)
        }
        try? FileManager.default.removeItem(at: payloadURL)
        return destination
    } catch {
        try? FileManager.default.removeItem(at: unpackRoot)
        throw error
    }
}

func uniqueDestinationURL(directory: URL, fileName: String) -> URL {
    let safeName = URL(fileURLWithPath: fileName).lastPathComponent
    let base = directory.appendingPathComponent(safeName)
    if !FileManager.default.fileExists(atPath: base.path) { return base }
    let ext = base.pathExtension
    let stem = base.deletingPathExtension().lastPathComponent
    var index = 1
    while true {
        let name = ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
        let candidate = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        index += 1
    }
}

private func runPublishingProcess(executable: String, arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw HMTransError.system("文件夹解压失败")
    }
}
