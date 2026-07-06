import Foundation
import PureSendCore

struct TransferListItem: Identifiable, Equatable {
    enum Direction: String {
        case sending = "发送"
        case receiving = "接收"
    }

    enum StateText: String {
        case active = "传输中"
        case done = "已完成"
        case failed = "失败"
    }

    let id: UUID
    var fileName: String
    var peerName: String
    var direction: Direction
    var progress: Double
    var detail: String
    var state: StateText
    var timeText: String
    var startedAt: Date
    var fileSize: Int64
    var fileType: String
    var localPath: String?

    var localURL: URL? {
        guard let localPath, !localPath.isEmpty else { return nil }
        return URL(fileURLWithPath: localPath)
    }

    init(
        id: UUID = UUID(),
        fileName: String,
        peerName: String,
        direction: Direction,
        progress: Double,
        detail: String,
        state: StateText = .active,
        timeText: String = Self.nowText(),
        startedAt: Date = Date(),
        fileSize: Int64 = 0,
        fileType: String = "",
        localPath: String? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.peerName = peerName
        self.direction = direction
        self.progress = progress
        self.detail = detail
        self.state = state
        self.timeText = timeText
        self.startedAt = startedAt
        self.fileSize = fileSize
        self.fileType = fileType
        self.localPath = localPath
    }

    static func nowText() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date())
    }
}

struct PreparedSendFile {
    let url: URL
    let displayName: String
    let cleanupDirectory: URL?

    func cleanup() {
        guard let cleanupDirectory else { return }
        try? FileManager.default.removeItem(at: cleanupDirectory)
    }
}

func prepareSendFileForTransfer(_ url: URL) throws -> PreparedSendFile {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
        throw PureSendError.system("文件不存在：\(url.path)")
    }
    guard isDirectory.boolValue else {
        return PreparedSendFile(url: url, displayName: url.lastPathComponent, cleanupDirectory: nil)
    }

    let tempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PureSend-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    let archiveURL = tempDirectory
        .appendingPathComponent(url.deletingPathExtension().lastPathComponent)
        .appendingPathExtension("zip")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", url.path, archiveURL.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        try? FileManager.default.removeItem(at: tempDirectory)
        throw PureSendError.system("文件夹压缩失败：\(url.lastPathComponent)")
    }

    return PreparedSendFile(url: archiveURL, displayName: archiveURL.lastPathComponent, cleanupDirectory: tempDirectory)
}
