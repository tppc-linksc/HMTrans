import Foundation
import OSLog
import SQLite3

/// v0.2 本地状态仓库。文件字节始终留在 Staging；SQLite 只保存任务、设备和检查点元数据。
final class TransferStore: @unchecked Sendable {
    struct Snapshot {
        var current: [TransferListItem]
        var history: [TransferListItem]
        var devices: [PersistedDevice]
    }

    private let queue = DispatchQueue(label: "HMTrans.TransferStore")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let log = Logger(subsystem: "com.linksc.hmtrans", category: "database")
    private var database: OpaquePointer?
    private var persistedTransferRows: [String: String] = [:]
    private var pendingError: String?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder.dateDecodingStrategy = .millisecondsSince1970
        queue.setSpecific(key: queueKey, value: 1)
        queue.sync {
            openDatabase()
            migrate()
        }
    }

    deinit {
        let closeDatabase = { [self] in
            if let database = self.database {
                sqlite3_close(database)
            }
            self.database = nil
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            closeDatabase()
        } else {
            queue.sync(execute: closeDatabase)
        }
    }

    func loadSnapshot() -> Snapshot {
        queue.sync {
            var current: [TransferListItem] = []
            var history: [TransferListItem] = []
            var devices: [PersistedDevice] = []

            query("SELECT id, bucket, payload FROM transfers ORDER BY updated_at DESC") { statement in
                guard let idText = sqlite3_column_text(statement, 0),
                      let bucketText = sqlite3_column_text(statement, 1),
                      let payloadText = sqlite3_column_text(statement, 2)
                else { return }
                let id = String(cString: idText)
                let bucket = String(cString: bucketText)
                let payload = Data(String(cString: payloadText).utf8)
                persistedTransferRows[id] = bucket + "\u{0}" + String(cString: payloadText)
                guard let item = try? decoder.decode(TransferListItem.self, from: payload) else {
                    report("decode transfer \(id)")
                    return
                }
                if bucket == "history" { history.append(item) } else { current.append(item) }
            }

            query("SELECT payload FROM devices ORDER BY last_seen_at DESC") { statement in
                guard let payloadText = sqlite3_column_text(statement, 0) else { return }
                let payload = Data(String(cString: payloadText).utf8)
                guard let device = try? decoder.decode(PersistedDevice.self, from: payload) else {
                    report("decode persisted device")
                    return
                }
                devices.append(device)
            }
            return Snapshot(current: current, history: history, devices: devices)
        }
    }

    func consumeLastError() -> String? {
        queue.sync {
            defer { pendingError = nil }
            return pendingError
        }
    }

    func save(current: [TransferListItem], history: [TransferListItem]) {
        queue.async { [weak self] in
            self?.saveLocked(current: current, history: history)
        }
    }

    func saveImmediately(current: [TransferListItem], history: [TransferListItem]) {
        queue.sync {
            saveLocked(current: current, history: history)
        }
    }

    func upsert(device: PersistedDevice) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let payload = try? encoder.encode(device),
                  let text = String(data: payload, encoding: .utf8) else {
                self.report("encode persisted device \(device.id)")
                return
            }
            withStatement("INSERT INTO devices (id, payload, last_seen_at) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload, last_seen_at=excluded.last_seen_at") { statement in
                bind(device.id, at: 1, statement: statement)
                bind(text, at: 2, statement: statement)
                sqlite3_bind_double(statement, 3, device.lastSeenAt.timeIntervalSince1970)
                step(statement, operation: "upsert device")
            }
        }
    }

    func removeDevice(id: String) {
        queue.async { [weak self] in
            self?.withStatement("DELETE FROM devices WHERE id = ?") { statement in
                self?.bind(id, at: 1, statement: statement)
                self?.step(statement, operation: "delete device")
            }
        }
    }

    /// 记录稳定且仅保存在本机的诊断事件。调用前必须确保消息不含文件内容和配对码。
    func recordDiagnostic(
        code: String,
        module: String,
        message: String,
        transferID: String? = nil,
        deviceID: String? = nil,
        level: String = "error"
    ) {
        queue.async { [weak self] in
            self?.withStatement("INSERT INTO diagnostic_events (created_at, level, module, transfer_id, device_id, error_code, message) VALUES (?, ?, ?, ?, ?, ?, ?)") { statement in
                sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
                self?.bind(level, at: 2, statement: statement)
                self?.bind(module, at: 3, statement: statement)
                self?.bind(transferID, at: 4, statement: statement)
                self?.bind(deviceID, at: 5, statement: statement)
                self?.bind(code, at: 6, statement: statement)
                self?.bind(message, at: 7, statement: statement)
                self?.step(statement, operation: "insert diagnostic event")
            }
            self?.execute("DELETE FROM diagnostic_events WHERE id NOT IN (SELECT id FROM diagnostic_events ORDER BY created_at DESC LIMIT 500)")
        }
    }

    func recentDiagnosticSummary(limit: Int = 12) -> [String] {
        queue.sync {
            var rows: [String] = []
            withStatement("SELECT error_code, module, message FROM diagnostic_events ORDER BY created_at DESC LIMIT ?") { statement in
                sqlite3_bind_int(statement, 1, Int32(max(1, limit)))
                while sqlite3_step(statement) == SQLITE_ROW {
                    let code = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "unknown"
                    let module = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "unknown"
                    let message = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
                    rows.append("[\(code)] \(module)：\(message)")
                }
            }
            return rows
        }
    }

    private func openDatabase() {
        let fileManager = FileManager.default
        let root = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ))?.appendingPathComponent("HMTrans", isDirectory: true)
        guard let root else { return }
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            report("create database directory", detail: error.localizedDescription)
            return
        }
        let path = root.appendingPathComponent("HMTrans.sqlite3").path
        guard sqlite3_open(path, &database) == SQLITE_OK else {
            report("open database")
            database = nil
            return
        }
        execute("PRAGMA journal_mode=WAL")
        execute("PRAGMA synchronous=NORMAL")
        execute("PRAGMA foreign_keys=ON")
    }

    private func migrate() {
        // 版本 2 只保留已有完整读写路径的表。分组、检查点和产物元数据已存于
        // 持久化传输载荷与应用私有暂存文件中。
        execute("DROP TABLE IF EXISTS transfer_groups")
        execute("DROP TABLE IF EXISTS checkpoints")
        execute("DROP TABLE IF EXISTS artifacts")
        execute("CREATE TABLE IF NOT EXISTS devices (id TEXT PRIMARY KEY, payload TEXT NOT NULL, last_seen_at REAL NOT NULL)")
        execute("CREATE TABLE IF NOT EXISTS transfers (id TEXT PRIMARY KEY, bucket TEXT NOT NULL, state TEXT NOT NULL, device_id TEXT, group_id TEXT, progress REAL NOT NULL, payload TEXT NOT NULL, updated_at REAL NOT NULL)")
        execute("CREATE INDEX IF NOT EXISTS idx_transfers_bucket_updated ON transfers(bucket, updated_at DESC)")
        execute("CREATE TABLE IF NOT EXISTS diagnostic_events (id INTEGER PRIMARY KEY AUTOINCREMENT, created_at REAL NOT NULL, level TEXT NOT NULL, module TEXT NOT NULL, transfer_id TEXT, device_id TEXT, error_code TEXT, message TEXT NOT NULL)")
        execute("PRAGMA user_version=2")
    }

    @discardableResult
    private func insert(item: TransferListItem, bucket: String) -> Bool {
        guard let payload = try? encoder.encode(item),
              let text = String(data: payload, encoding: .utf8)
        else {
            report("encode transfer \(item.id)")
            return false
        }
        var succeeded = false
        withStatement("INSERT OR REPLACE INTO transfers (id, bucket, state, device_id, group_id, progress, payload, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)") { statement in
            bind(item.id.uuidString, at: 1, statement: statement)
            bind(bucket, at: 2, statement: statement)
            bind(item.state.rawValue, at: 3, statement: statement)
            bind(item.deviceId, at: 4, statement: statement)
            bind(item.groupId?.uuidString, at: 5, statement: statement)
            sqlite3_bind_double(statement, 6, item.progress)
            bind(text, at: 7, statement: statement)
            sqlite3_bind_double(statement, 8, item.updatedAt.timeIntervalSince1970)
            succeeded = step(statement, operation: "upsert transfer")
        }
        return succeeded
    }

    private func saveLocked(current: [TransferListItem], history: [TransferListItem]) {
        guard execute("BEGIN IMMEDIATE TRANSACTION") else { return }
        var nextRows: [String: String] = [:]
        let rows = current.map { ($0, "current") } + history.map { ($0, "history") }
        for (item, bucket) in rows {
            guard let payload = try? encoder.encode(item),
                  let text = String(data: payload, encoding: .utf8)
            else {
                report("encode transfer \(item.id)")
                execute("ROLLBACK")
                return
            }
            let id = item.id.uuidString
            let fingerprint = bucket + "\u{0}" + text
            nextRows[id] = fingerprint
            if persistedTransferRows[id] != fingerprint,
               !insert(item: item, bucket: bucket) {
                execute("ROLLBACK")
                return
            }
        }
        for removedID in persistedTransferRows.keys where nextRows[removedID] == nil {
            var removed = false
            withStatement("DELETE FROM transfers WHERE id = ?") { statement in
                bind(removedID, at: 1, statement: statement)
                removed = step(statement, operation: "delete transfer")
            }
            if !removed {
                execute("ROLLBACK")
                return
            }
        }
        guard execute("COMMIT") else {
            execute("ROLLBACK")
            return
        }
        persistedTransferRows = nextRows
    }

    private func query(_ sql: String, row: (OpaquePointer) -> Void) {
        withStatement(sql) { statement in
            while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
        }
    }

    @discardableResult
    private func execute(_ sql: String) -> Bool {
        guard let database else {
            report("execute SQL", detail: "database is unavailable")
            return false
        }
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        if result != SQLITE_OK {
            report("execute SQL")
            return false
        }
        return true
    }

    private func withStatement(_ sql: String, body: (OpaquePointer) -> Void) {
        guard let database else {
            report("prepare SQL", detail: "database is unavailable")
            return
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            report("prepare SQL")
            return
        }
        defer { sqlite3_finalize(statement) }
        body(statement)
    }

    @discardableResult
    private func step(_ statement: OpaquePointer, operation: String) -> Bool {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            report(operation)
            return false
        }
        return true
    }

    private func report(_ operation: String, detail: String? = nil) {
        let sqliteDetail = database.map { String(cString: sqlite3_errmsg($0)) }
        let message = "\(operation): \(detail ?? sqliteDetail ?? "unknown SQLite error")"
        pendingError = message
        log.error("\(message, privacy: .public)")
    }

    private func bind(_ value: String?, at index: Int32, statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
}
