import Foundation

/// Publishes a verified payload atomically. Folder archives stay private until
/// all archive paths have been validated and extraction has completed.
func publishReceivedPayload(
    meta: FileMeta,
    payloadURL: URL,
    defaultDestination: URL,
    outputDirectory: URL,
    stagingRoot: URL
) throws -> URL {
    guard meta.sourceKind == "folder", meta.payloadKind == "zip" else {
        if FileManager.default.fileExists(atPath: defaultDestination.path) {
            try FileManager.default.removeItem(at: defaultDestination)
        }
        try FileManager.default.moveItem(at: payloadURL, to: defaultDestination)
        return defaultDestination
    }

    try validateZipEntries(payloadURL)
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
        let sourceName = meta.sourceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = uniqueDestinationURL(
            directory: outputDirectory,
            fileName: sourceName?.isEmpty == false ? sourceName! : "接收的文件夹"
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

private func validateZipEntries(_ archiveURL: URL) throws {
    let pipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
    process.arguments = ["-1", archiveURL.path]
    process.standardOutput = pipe
    process.standardError = Pipe()
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw HMTransError.protocolError("文件夹压缩包无法读取")
    }
    for rawEntry in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        let entry = rawEntry.replacingOccurrences(of: "\\", with: "/")
        let components = entry.split(separator: "/", omittingEmptySubsequences: false)
        if entry.hasPrefix("/") || components.contains("..") {
            throw HMTransError.protocolError("文件夹压缩包包含不安全路径")
        }
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
