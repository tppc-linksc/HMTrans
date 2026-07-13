import { common } from '@kit.AbilityKit'
import { relationalStore } from '@kit.ArkData'
import { TransferListItem, TransferListItemOptions } from '../models/TransferListItem'
import { DeviceInfo } from '../common/Protocol'
import { errorText } from '../common/ErrorText'

const DATABASE_NAME: string = 'HMTrans.db'
const SNAPSHOT_KEY: string = 'transfer_snapshot'

export interface TransferSnapshotPayload {
  current: Array<TransferListItemOptions>
  history: Array<TransferListItemOptions>
}

export interface TransferSnapshot {
  current: Array<TransferListItem>
  history: Array<TransferListItem>
}

export class TransferStore {
  private store?: relationalStore.RdbStore
  // 所有快照写入按调用顺序串行执行，避免进度更新与“清空历史”等操作交错后旧状态回写。
  private saveChain: Promise<void> = Promise.resolve()

  async initialize(context: common.UIAbilityContext): Promise<void> {
    if (this.store) return
    this.store = await relationalStore.getRdbStore(context, {
      name: DATABASE_NAME,
      securityLevel: relationalStore.SecurityLevel.S1,
    })
    await this.createSchema()
  }

  async loadSnapshot(): Promise<TransferSnapshot> {
    const empty: TransferSnapshot = { current: [], history: [] }
    if (!this.store) return empty
    const records = await this.store.querySql(
      'SELECT record_id, bucket, payload FROM transfer_records ORDER BY updated_at DESC'
    )
    const snapshot: TransferSnapshot = { current: [], history: [] }
    const corruptRecordIds: Array<string> = []
    try {
      while (records.goToNextRow()) {
        const recordId = records.getString(records.getColumnIndex('record_id'))
        const bucket = records.getString(records.getColumnIndex('bucket'))
        const payload = records.getString(records.getColumnIndex('payload'))
        try {
          const item = new TransferListItem(JSON.parse(payload) as TransferListItemOptions)
          if (bucket === 'current') snapshot.current.push(item)
          if (bucket === 'history') snapshot.history.push(item)
        } catch (_) {
          // 单条记录损坏不能阻止其余任务恢复；保留原始行供诊断，不擅自删除用户历史。
          corruptRecordIds.push(recordId)
        }
      }
    } finally {
      records.close()
    }
    for (let index = 0; index < corruptRecordIds.length; index += 1) {
      await this.recordDiagnostic('DB-TRANSFER-001',
        `传输记录无法解析：${corruptRecordIds[index]}`)
    }
    if (snapshot.current.length > 0 || snapshot.history.length > 0) return snapshot

    // 首次升级时兼容 v0.2 早期的单行 JSON 快照，迁移成功后由行级表接管。
    const result = await this.store.querySql('SELECT value FROM app_state WHERE key = ?', [SNAPSHOT_KEY])
    let legacy: TransferSnapshot
    try {
      if (!result.goToFirstRow()) {
        return empty
      }
      const valueColumn = result.getColumnIndex('value')
      if (valueColumn < 0) throw new Error('数据库缺少 app_state.value 列')
      const value = result.getString(valueColumn)
      const payload = JSON.parse(value) as TransferSnapshotPayload
      legacy = {
        current: payload.current.map((item: TransferListItemOptions) => new TransferListItem(item)),
        history: payload.history.map((item: TransferListItemOptions) => new TransferListItem(item)),
      }
    } catch (err) {
      throw new Error(`传输快照读取失败：${errorText(err)}`)
    } finally {
      result.close()
    }
    // 先关闭旧快照游标再写入，避免同一数据库连接在迁移时处于读写竞争状态。
    await this.saveSnapshot(legacy.current, legacy.history)
    return legacy
  }

  async saveSnapshot(current: Array<TransferListItem>, history: Array<TransferListItem>): Promise<void> {
    const currentSnapshot = current.map((item: TransferListItem) => item.toOptions())
    const historySnapshot = history.map((item: TransferListItem) => item.toOptions())
    const task = this.saveChain.then(() => this.saveOptions(currentSnapshot, historySnapshot))
    // 调用方仍会收到 task 的异常；链尾吞掉旧异常只是为了让后续保存有机会继续执行。
    this.saveChain = task.catch(() => {})
    await task
  }

  private async saveOptions(current: Array<TransferListItemOptions>,
    history: Array<TransferListItemOptions>): Promise<void> {
    if (!this.store) return
    const desired: Map<string, TransferListItemOptions> = new Map()
    const buckets: Map<string, string> = new Map()
    current.forEach((item: TransferListItemOptions) => {
      desired.set(item.id, item); buckets.set(item.id, 'current')
    })
    history.forEach((item: TransferListItemOptions) => {
      desired.set(item.id, item); buckets.set(item.id, 'history')
    })

    const existing: Map<string, number> = new Map()
    const rows = await this.store.querySql('SELECT record_id, updated_at FROM transfer_records')
    try {
      while (rows.goToNextRow()) {
        existing.set(rows.getString(rows.getColumnIndex('record_id')),
          rows.getLong(rows.getColumnIndex('updated_at')))
      }
    } finally {
      rows.close()
    }

    const desiredIds = Array.from(desired.keys())
    for (let index = 0; index < desiredIds.length; index += 1) {
      const id = desiredIds[index]
      const item = desired.get(id)
      if (!item) continue
      if (existing.get(id) === item.updatedAt) continue
      await this.store.executeSql(
        'INSERT OR REPLACE INTO transfer_records (record_id, bucket, updated_at, payload) VALUES (?, ?, ?, ?)',
        [id, buckets.get(id) ?? 'history', item.updatedAt, JSON.stringify(item)]
      )
    }
    const existingIds = Array.from(existing.keys())
    for (let index = 0; index < existingIds.length; index += 1) {
      const id = existingIds[index]
      if (!desired.has(id)) {
        await this.store.executeSql('DELETE FROM transfer_records WHERE record_id = ?', [id])
      }
    }
    // 行级表保存成功后清除旧快照，避免用户清空记录后旧数据在下次启动时复活。
    await this.store.executeSql('DELETE FROM app_state WHERE key = ?', [SNAPSHOT_KEY])
  }

  async clearHistory(current: Array<TransferListItem>): Promise<void> {
    await this.saveSnapshot(current, [])
  }

  async loadDevices(): Promise<Array<DeviceInfo>> {
    const devices: Array<DeviceInfo> = []
    let corruptCount: number = 0
    if (!this.store) {
      return devices
    }
    const result = await this.store.querySql('SELECT payload FROM devices ORDER BY last_seen_at DESC')
    try {
      while (result.goToNextRow()) {
        const payloadColumn = result.getColumnIndex('payload')
        if (payloadColumn < 0) throw new Error('数据库缺少 devices.payload 列')
        const payload = result.getString(payloadColumn)
        try {
          devices.push(JSON.parse(payload) as DeviceInfo)
        } catch (_) {
          corruptCount += 1
        }
      }
    } finally {
      result.close()
    }
    if (corruptCount > 0) {
      await this.recordDiagnostic('DB-DEVICE-001', `有 ${corruptCount} 条设备记录无法解析`)
    }
    return devices
  }

  async upsertDevice(device: DeviceInfo): Promise<void> {
    if (!this.store) {
      return
    }
    const now = Date.now()
    await this.store.executeSql(
      'INSERT OR REPLACE INTO devices (device_id, name, platform, system_version, paired_at, last_seen_at, payload) VALUES (?, ?, ?, ?, COALESCE((SELECT paired_at FROM devices WHERE device_id = ?), ?), ?, ?)',
      [device.deviceId, device.deviceName, device.platform, device.version, device.deviceId, now, now, JSON.stringify(device)]
    )
  }

  async removeDevice(deviceId: string): Promise<void> {
    if (!this.store) return
    await this.store.executeSql('DELETE FROM devices WHERE device_id = ?', [deviceId])
  }

  async recordDiagnostic(code: string, message: string, transferId?: string): Promise<void> {
    if (!this.store) {
      return
    }
    await this.store.executeSql(
      'INSERT INTO diagnostic_events (transfer_id, code, message, created_at) VALUES (?, ?, ?, ?)',
      [transferId ?? null, code, message, Date.now()]
    )
    await this.store.executeSql(
      'DELETE FROM diagnostic_events WHERE event_id NOT IN (SELECT event_id FROM diagnostic_events ORDER BY created_at DESC LIMIT 500)'
    )
  }

  async recentDiagnosticSummary(limit: number = 12): Promise<Array<string>> {
    const rows: Array<string> = []
    if (!this.store) {
      return rows
    }
    const result = await this.store.querySql(
      'SELECT code, message FROM diagnostic_events ORDER BY created_at DESC LIMIT ?',
      [Math.max(1, limit)]
    )
    try {
      while (result.goToNextRow()) {
        rows.push(`[${result.getString(0)}] ${result.getString(1)}`)
      }
    } finally {
      result.close()
    }
    return rows
  }

  private async createSchema(): Promise<void> {
    if (!this.store) {
      return
    }
    await this.store.executeSql('PRAGMA journal_mode=WAL')
    // 旧原型表从未承载有效数据；v3 使用按任务存储的 transfer_records，避免进度更新时重写整份历史。
    await this.store.executeSql('DROP TABLE IF EXISTS transfer_groups')
    await this.store.executeSql('DROP TABLE IF EXISTS transfers')
    await this.store.executeSql('DROP TABLE IF EXISTS checkpoints')
    await this.store.executeSql('DROP TABLE IF EXISTS artifacts')
    await this.store.executeSql('CREATE TABLE IF NOT EXISTS devices (device_id TEXT PRIMARY KEY, name TEXT NOT NULL, platform TEXT NOT NULL, system_version TEXT NOT NULL, paired_at INTEGER NOT NULL, last_seen_at INTEGER NOT NULL, payload TEXT NOT NULL)')
    await this.store.executeSql('CREATE TABLE IF NOT EXISTS diagnostic_events (event_id INTEGER PRIMARY KEY AUTOINCREMENT, transfer_id TEXT, code TEXT NOT NULL, message TEXT NOT NULL, created_at INTEGER NOT NULL)')
    await this.store.executeSql('CREATE TABLE IF NOT EXISTS app_state (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at INTEGER NOT NULL)')
    await this.store.executeSql('CREATE TABLE IF NOT EXISTS transfer_records (record_id TEXT PRIMARY KEY, bucket TEXT NOT NULL, updated_at INTEGER NOT NULL, payload TEXT NOT NULL)')
    await this.store.executeSql('CREATE INDEX IF NOT EXISTS idx_transfer_records_bucket_time ON transfer_records(bucket, updated_at DESC)')
    await this.store.executeSql('PRAGMA user_version=3')
  }
}
