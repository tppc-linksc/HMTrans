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
    let names = try captureZipInfo(arguments: ["-1", archiveURL.path])
    let entries = String(decoding: names, as: UTF8.self).split(separator: "\n")
    guard entries.count <= 100_000 else {
        throw HMTransError.protocolError("文件夹压缩包条目过多")
    }
    for rawEntry in entries {
        let entry = rawEntry.replacingOccurrences(of: "\\", with: "/")
        let components = entry.split(separator: "/", omittingEmptySubsequences: false)
        let hasDrivePrefix = entry.count >= 3
            && entry[entry.index(entry.startIndex, offsetBy: 1)] == ":"
            && entry[entry.index(entry.startIndex, offsetBy: 2)] == "/"
        if entry.hasPrefix("/") || hasDrivePrefix || components.contains("..") {
            throw HMTransError.protocolError("文件夹压缩包包含不安全路径")
        }
    }

    // ditto preserves symbolic links. Reject them before extraction so an
    // archive cannot publish a link that escapes the chosen destination.
    let longListing = try captureZipInfo(arguments: ["-l", archiveURL.path])
    for line in String(decoding: longListing, as: UTF8.self).split(separator: "\n") {
        if line.first == "l" {
            throw HMTransError.protocolError("文件夹压缩包包含符号链接")
        }
    }
}

private func captureZipInfo(arguments: [String], byteLimit: Int = 32 * 1_024 * 1_024) throws -> Data {
    let pipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = Pipe()
    try process.run()

    var output = Data()
    while true {
        let chunk = pipe.fileHandleForReading.readData(ofLength: 64 * 1_024)
        if chunk.isEmpty { break }
        guard output.count + chunk.count <= byteLimit else {
            process.terminate()
            process.waitUntilExit()
            throw HMTransError.protocolError("文件夹压缩包目录信息过大")
        }
        output.append(chunk)
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw HMTransError.protocolError("文件夹压缩包无法读取")
    }
    return output
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
