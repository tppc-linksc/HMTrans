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
    if (!this.store) {
      return empty
    }
    const result = await this.store.querySql('SELECT value FROM app_state WHERE key = ?', [SNAPSHOT_KEY])
    try {
      if (!result.goToFirstRow()) {
        return empty
      }
      const valueColumn = result.getColumnIndex('value')
      if (valueColumn < 0) throw new Error('数据库缺少 app_state.value 列')
      const value = result.getString(valueColumn)
      const payload = JSON.parse(value) as TransferSnapshotPayload
      return {
        current: payload.current.map((item: TransferListItemOptions) => new TransferListItem(item)),
        history: payload.history.map((item: TransferListItemOptions) => new TransferListItem(item)),
      }
    } catch (err) {
      throw new Error(`传输快照读取失败：${errorText(err)}`)
    } finally {
      result.close()
    }
  }

  async saveSnapshot(current: Array<TransferListItem>, history: Array<TransferListItem>): Promise<void> {
    if (!this.store) {
      return
    }
    const payload: TransferSnapshotPayload = {
      current: current.map((item: TransferListItem) => item.toOptions()),
      history: history.map((item: TransferListItem) => item.toOptions()),
    }
    await this.store.executeSql(
      'INSERT OR REPLACE INTO app_state (key, value, updated_at) VALUES (?, ?, ?)',
      [SNAPSHOT_KEY, JSON.stringify(payload), Date.now()]
    )
  }

  async clearHistory(current: Array<TransferListItem>): Promise<void> {
    await this.saveSnapshot(current, [])
  }

  async loadDevices(): Promise<Array<DeviceInfo>> {
    const devices: Array<DeviceInfo> = []
    if (!this.store) {
      return devices
    }
    const result = await this.store.querySql('SELECT payload FROM devices ORDER BY last_seen_at DESC')
    try {
      while (result.goToNextRow()) {
        const payloadColumn = result.getColumnIndex('payload')
        if (payloadColumn < 0) throw new Error('数据库缺少 devices.payload 列')
        const payload = result.getString(payloadColumn)
        devices.push(JSON.parse(payload) as DeviceInfo)
      }
    } catch (err) {
      throw new Error(`设备记录读取失败：${errorText(err)}`)
    } finally {
      result.close()
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
    // v0.2 将传输状态作为一个原子快照持久化。这些原型表从未被读写，且暗示了并不存在的迁移，
    // 因此将其删除，但不触碰设备、历史和诊断数据。
    await this.store.executeSql('DROP TABLE IF EXISTS transfer_groups')
    await this.store.executeSql('DROP TABLE IF EXISTS transfers')
    await this.store.executeSql('DROP TABLE IF EXISTS checkpoints')
    await this.store.executeSql('DROP TABLE IF EXISTS artifacts')
    await this.store.executeSql('CREATE TABLE IF NOT EXISTS devices (device_id TEXT PRIMARY KEY, name TEXT NOT NULL, platform TEXT NOT NULL, system_version TEXT NOT NULL, paired_at INTEGER NOT NULL, last_seen_at INTEGER NOT NULL, payload TEXT NOT NULL)')
    await this.store.executeSql('CREATE TABLE IF NOT EXISTS diagnostic_events (event_id INTEGER PRIMARY KEY AUTOINCREMENT, transfer_id TEXT, code TEXT NOT NULL, message TEXT NOT NULL, created_at INTEGER NOT NULL)')
    await this.store.executeSql('CREATE TABLE IF NOT EXISTS app_state (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at INTEGER NOT NULL)')
    await this.store.executeSql('PRAGMA user_version=2')
  }
}
