import Foundation
import SQLite3

/// v0.2 本地状态仓库。文件字节始终留在 Staging；SQLite 只保存任务、设备和检查点元数据。
final class TransferStore: @unchecked Sendable {
    struct Snapshot {
        var current: [TransferListItem]
        var history: [TransferListItem]
        var devices: [PersistedDevice]
    }

    private let queue = DispatchQueue(label: "HMTrans.TransferStore")
    private var database: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder.dateDecodingStrategy = .millisecondsSince1970
        queue.sync {
            openDatabase()
            migrate()
        }
    }

    deinit {
        queue.sync {
            if let database {
                sqlite3_close(database)
            }
            database = nil
        }
    }

    func loadSnapshot() -> Snapshot {
        queue.sync {
            var current: [TransferListItem] = []
            var history: [TransferListItem] = []
            var devices: [PersistedDevice] = []

            query("SELECT bucket, payload FROM transfers ORDER BY updated_at DESC") { statement in
                guard let bucketText = sqlite3_column_text(statement, 0),
                      let payloadText = sqlite3_column_text(statement, 1)
                else { return }
                let bucket = String(cString: bucketText)
                let payload = Data(String(cString: payloadText).utf8)
                guard let item = try? decoder.decode(TransferListItem.self, from: payload) else { return }
                if bucket == "history" { history.append(item) } else { current.append(item) }
            }

            query("SELECT payload FROM devices ORDER BY last_seen_at DESC") { statement in
                guard let payloadText = sqlite3_column_text(statement, 0) else { return }
                let payload = Data(String(cString: payloadText).utf8)
                if let device = try? decoder.decode(PersistedDevice.self, from: payload) {
                    devices.append(device)
                }
            }
            return Snapshot(current: current, history: history, devices: devices)
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
            guard let self, let payload = try? encoder.encode(device),
                  let text = String(data: payload, encoding: .utf8)
            else { return }
            withStatement("INSERT INTO devices (id, payload, last_seen_at) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload, last_seen_at=excluded.last_seen_at") { statement in
                bind(device.id, at: 1, statement: statement)
                bind(text, at: 2, statement: statement)
                sqlite3_bind_double(statement, 3, device.lastSeenAt.timeIntervalSince1970)
                sqlite3_step(statement)
            }
        }
    }

    func removeDevice(id: String) {
        queue.async { [weak self] in
            self?.withStatement("DELETE FROM devices WHERE id = ?") { statement in
                self?.bind(id, at: 1, statement: statement)
                sqlite3_step(statement)
            }
        }
    }

    /// Records a stable, local-only diagnostic event. Messages must already be
    /// free of file contents and pairing codes before entering this method.
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
                sqlite3_step(statement)
            }
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
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("HMTrans.sqlite3").path
        guard sqlite3_open(path, &database) == SQLITE_OK else {
            database = nil
            return
        }
        execute("PRAGMA journal_mode=WAL")
        execute("PRAGMA synchronous=NORMAL")
        execute("PRAGMA foreign_keys=ON")
    }

    private func migrate() {
        execute("CREATE TABLE IF NOT EXISTS devices (id TEXT PRIMARY KEY, payload TEXT NOT NULL, last_seen_at REAL NOT NULL)")
        execute("CREATE TABLE IF NOT EXISTS transfer_groups (id TEXT PRIMARY KEY, state TEXT NOT NULL, created_at REAL NOT NULL, completed_at REAL)")
        execute("CREATE TABLE IF NOT EXISTS transfers (id TEXT PRIMARY KEY, bucket TEXT NOT NULL, state TEXT NOT NULL, device_id TEXT, group_id TEXT, progress REAL NOT NULL, payload TEXT NOT NULL, updated_at REAL NOT NULL)")
        execute("CREATE INDEX IF NOT EXISTS idx_transfers_bucket_updated ON transfers(bucket, updated_at DESC)")
        execute("CREATE TABLE IF NOT EXISTS checkpoints (transfer_id TEXT PRIMARY KEY, confirmed_offset INTEGER NOT NULL, chunk_size INTEGER NOT NULL, last_chunk_hash TEXT, updated_at REAL NOT NULL, generation INTEGER NOT NULL DEFAULT 0)")
        execute("CREATE TABLE IF NOT EXISTS artifacts (id TEXT PRIMARY KEY, path TEXT NOT NULL, purpose TEXT NOT NULL, size INTEGER NOT NULL DEFAULT 0, ref_count INTEGER NOT NULL DEFAULT 1, expires_at REAL)")
        execute("CREATE TABLE IF NOT EXISTS diagnostic_events (id INTEGER PRIMARY KEY AUTOINCREMENT, created_at REAL NOT NULL, level TEXT NOT NULL, module TEXT NOT NULL, transfer_id TEXT, device_id TEXT, error_code TEXT, message TEXT NOT NULL)")
    }

    private func insert(item: TransferListItem, bucket: String) {
        guard let payload = try? encoder.encode(item),
              let text = String(data: payload, encoding: .utf8)
        else { return }
        withStatement("INSERT OR REPLACE INTO transfers (id, bucket, state, device_id, group_id, progress, payload, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)") { statement in
            bind(item.id.uuidString, at: 1, statement: statement)
            bind(bucket, at: 2, statement: statement)
            bind(item.state.rawValue, at: 3, statement: statement)
            bind(item.deviceId, at: 4, statement: statement)
            bind(item.groupId?.uuidString, at: 5, statement: statement)
            sqlite3_bind_double(statement, 6, item.progress)
            bind(text, at: 7, statement: statement)
            sqlite3_bind_double(statement, 8, item.updatedAt.timeIntervalSince1970)
            sqlite3_step(statement)
        }
    }

    private func saveLocked(current: [TransferListItem], history: [TransferListItem]) {
        execute("BEGIN IMMEDIATE TRANSACTION")
        execute("DELETE FROM transfers")
        for item in current { insert(item: item, bucket: "current") }
        for item in history { insert(item: item, bucket: "history") }
        execute("COMMIT")
    }

    private func query(_ sql: String, row: (OpaquePointer) -> Void) {
        withStatement(sql) { statement in
            while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
        }
    }

    private func execute(_ sql: String) {
        guard let database else { return }
        sqlite3_exec(database, sql, nil, nil, nil)
    }

    private func withStatement(_ sql: String, body: (OpaquePointer) -> Void) {
        guard let database else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return }
        defer { sqlite3_finalize(statement) }
        body(statement)
    }

    private func bind(_ value: String?, at index: Int32, statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
}
