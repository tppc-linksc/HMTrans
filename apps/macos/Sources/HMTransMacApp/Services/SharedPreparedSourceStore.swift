import Foundation

/// 在多设备传输组的所有子任务之间共享一个持久化文件夹归档。
/// 仅在最后一个子任务释放后清理；任一可续传子任务都会保留该产物。
final class SharedPreparedSourceStore: @unchecked Sendable {
    private struct Entry {
        let source: PreparedSendFile
        var remainingUsers: Int
        var preserveForResume: Bool
    }

    private let condition = NSCondition()
    private var entries: [String: Entry] = [:]
    private var preparing: Set<String> = []

    func acquire(url: URL, groupID: UUID) throws -> PreparedSendFile {
        let key = cacheKey(url: url, groupID: groupID)
        condition.lock()
        while preparing.contains(key) { condition.wait() }
        if var entry = entries[key] {
            // 只统计实际取得共享产物的发送任务。目标在 TCP 探测阶段失败时不会
            // 虚增引用数，因此最后一个真实使用者一定能完成清理。
            entry.remainingUsers += 1
            entries[key] = entry
            condition.unlock()
            return entry.source
        }
        preparing.insert(key)
        condition.unlock()

        do {
            let source = try prepareSendFileForTransfer(url, transferID: groupID)
            condition.lock()
            entries[key] = Entry(
                source: source,
                remainingUsers: 1,
                preserveForResume: false
            )
            preparing.remove(key)
            condition.broadcast()
            condition.unlock()
            return source
        } catch {
            condition.lock()
            preparing.remove(key)
            condition.broadcast()
            condition.unlock()
            throw error
        }
    }

    func release(url: URL, groupID: UUID, preserveForResume: Bool) {
        let key = cacheKey(url: url, groupID: groupID)
        condition.lock()
        guard var entry = entries[key] else {
            condition.unlock()
            return
        }
        entry.remainingUsers -= 1
        entry.preserveForResume = entry.preserveForResume || preserveForResume
        if entry.remainingUsers > 0 {
            entries[key] = entry
            condition.unlock()
            return
        }
        entries.removeValue(forKey: key)
        condition.unlock()
        if !entry.preserveForResume { entry.source.cleanup() }
    }

    private func cacheKey(url: URL, groupID: UUID) -> String {
        "\(groupID.uuidString)|\(url.standardizedFileURL.path)"
    }
}
