import Foundation

/// 维护应用私有的可续传产物，不触碰用户下载文件。
struct StagingMaintenanceService {
    private let fileManager = FileManager.default

    func pruneExpired(activeTransferIDs: Set<String>, retention: TimeInterval = 7 * 24 * 60 * 60) {
        guard let root = stagingRoot() else { return }
        let activeTokens = activeTransferIDs.map { $0.lowercased() }
        pruneChildren(of: root, activeTokens: activeTokens, cutoff: Date().addingTimeInterval(-retention))
    }

    private func stagingRoot() -> URL? {
        try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("HMTrans", isDirectory: true)
        .appendingPathComponent("Staging", isDirectory: true)
    }

    private func pruneChildren(of directory: URL, activeTokens: [String], cutoff: Date) {
        guard let children = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for child in children {
            let path = child.path.lowercased()
            if activeTokens.contains(where: path.contains) { continue }
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            if values?.isDirectory == true {
                pruneChildren(of: child, activeTokens: activeTokens, cutoff: cutoff)
                let isEmpty = (try? fileManager.contentsOfDirectory(atPath: child.path).isEmpty) == true
                if isEmpty, (values?.contentModificationDate ?? .distantPast) < cutoff {
                    try? fileManager.removeItem(at: child)
                }
            } else if (values?.contentModificationDate ?? .distantPast) < cutoff {
                try? fileManager.removeItem(at: child)
            }
        }
    }
}
