import Foundation

/// Shares one persisted folder archive across every child in a multi-device
/// transfer group. Cleanup happens only after the last child releases it, and
/// any resumable child keeps the artifact alive.
final class SharedPreparedSourceStore: @unchecked Sendable {
    private struct Entry {
        let source: PreparedSendFile
        var remainingUsers: Int
        var preserveForResume: Bool
    }

    private let condition = NSCondition()
    private var entries: [String: Entry] = [:]
    private var preparing: Set<String> = []

    func acquire(url: URL, groupID: UUID, participantCount: Int) throws -> PreparedSendFile {
        let key = cacheKey(url: url, groupID: groupID)
        condition.lock()
        while preparing.contains(key) { condition.wait() }
        if let entry = entries[key] {
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
                remainingUsers: max(1, participantCount),
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
