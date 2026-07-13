import Foundation
import HMTransCore

struct TransferListItem: Identifiable, Equatable, Codable, Sendable {
    enum Direction: String, Codable, Sendable {
        case sending = "发送"
        case receiving = "接收"
    }

    enum StateText: String, Codable, CaseIterable, Sendable {
        case queued = "排队中"
        case preparing = "准备中"
        case active = "传输中"
        case paused = "已暂停"
        case waiting = "等待重连"
        case verifying = "正在校验"
        case done = "已完成"
        case failed = "失败"
        case cancelled = "已取消"

        var isRecoverable: Bool {
            switch self {
            case .queued, .preparing, .active, .paused, .waiting, .failed:
                return true
            case .verifying, .done, .cancelled:
                return false
            }
        }

        var isActive: Bool {
            self == .queued || self == .preparing || self == .active || self == .verifying
        }
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
    var deviceId: String?
    var groupId: UUID?
    var errorCode: String?
    var confirmedOffset: Int64
    var updatedAt: Date

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
        localPath: String? = nil,
        deviceId: String? = nil,
        groupId: UUID? = nil,
        errorCode: String? = nil,
        confirmedOffset: Int64 = 0,
        updatedAt: Date = Date()
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
        self.deviceId = deviceId
        self.groupId = groupId
        self.errorCode = errorCode
        self.confirmedOffset = confirmedOffset
        self.updatedAt = updatedAt
    }

    static func nowText() -> String {
        let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: Date())
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }
}

struct PersistedDevice: Identifiable, Equatable, Codable, Sendable {
    let id: String
    var name: String
    var platform: String
    var systemVersion: String
    var address: String
    var port: UInt16
    var isPaired: Bool
    var lastSeenAt: Date
}

struct PreparedSendFile {
    let url: URL
    let displayName: String
    let cleanupDirectory: URL?
    let sourceKind: String
    let payloadKind: String
    let sourceName: String
    let sourceSize: Int64
    let sourceFileCount: Int

    func cleanup() {
        guard let cleanupDirectory else { return }
        try? FileManager.default.removeItem(at: cleanupDirectory)
    }
}

func prepareSendFileForTransfer(_ url: URL, transferID: UUID) throws -> PreparedSendFile {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
        throw HMTransError.system("文件不存在：\(url.path)")
    }
    guard isDirectory.boolValue else {
        return PreparedSendFile(
            url: url,
            displayName: url.lastPathComponent,
            cleanupDirectory: nil,
            sourceKind: "file",
            payloadKind: "file",
            sourceName: url.lastPathComponent,
            sourceSize: (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0,
            sourceFileCount: 1
        )
    }

    let supportRoot = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
    )
    let tempDirectory = supportRoot
        .appendingPathComponent("HMTrans/Staging/Outgoing", isDirectory: true)
        .appendingPathComponent(transferID.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    let archiveURL = tempDirectory
        .appendingPathComponent(url.deletingPathExtension().lastPathComponent)
        .appendingPathExtension("zip")

    if !FileManager.default.fileExists(atPath: archiveURL.path) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", url.path, archiveURL.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: tempDirectory)
            throw HMTransError.system("文件夹压缩失败：\(url.lastPathComponent)")
        }
    }

    var sourceSize: Int64 = 0
    var sourceFileCount = 0
    if let enumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
    ) {
        for case let child as URL in enumerator {
            let values = try? child.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true {
                sourceFileCount += 1
                sourceSize += Int64(values?.fileSize ?? 0)
            }
        }
    }

    return PreparedSendFile(
        url: archiveURL,
        // 不在任务列表和历史记录中展示内部 ZIP 名称。
        displayName: url.lastPathComponent,
        cleanupDirectory: tempDirectory,
        sourceKind: "folder",
        payloadKind: "zip",
        sourceName: url.lastPathComponent,
        sourceSize: sourceSize,
        sourceFileCount: sourceFileCount
    )
}
