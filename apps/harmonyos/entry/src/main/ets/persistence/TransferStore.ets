import { common } from '@kit.AbilityKit'
import { relationalStore } from '@kit.ArkData'
import { TransferListItem, TransferListItemOptions } from '../models/TransferListItem'
import { DeviceInfo } from '../common/Protocol'

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
      const value = result.getString(result.getColumnIndex('value'))
      const payload = JSON.parse(value) as TransferSnapshotPayload
      return {
        current: payload.current.map((item: TransferListItemOptions) => new TransferListItem(item)),
        history: payload.history.map((item: TransferListItemOptions) => new TransferListItem(item)),
      }
    } catch (_) {
      return empty
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
        const payload = result.getString(result.getColumnIndex('payload'))
        devices.push(JSON.parse(payload) as DeviceInfo)
      }
    } catch (_) {
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

  async recordDiagnostic(code: string, message: string, transferId?: string): Promise<void> {
    if (!this.store) {
      return
    }
    await this.store.executeSql(
      'INSERT INTO diagnostic_events (transfer_id, code, message, created_at) VALUES (?, ?, ?, ?)',
      [transferId ?? null, code, message, Date.now()]
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
    await this.store.executeSql('CREATE TABLE IF NOT EXISTS devices (device_id TEXT PRIMARY KEY, name TEXT NOT NULL, platform TEXT NOT NULL, system_version TEXT NOT NULL, paired_at INTEGER NOT NULL, last_seen_at INTEGER NOT NULL, payload TEXT NOT NULL)')
    await this.store.executeSql('CREATE TABLE IF NOT EXISTS transfer_groups (group_id TEXT PRIMARY KEY, device_id TEXT NOT NULL, state TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)')
    await this.store.executeSql('CREATE TABLE IF NOT EXISTS transfers (transfer_id TEXT PRIMARY KEY, group_id TEXT NOT NULL, device_id TEXT NOT NULL, state TEXT NOT NULL, file_name TEXT NOT NULL, file_size INTEGER NOT NULL, confirmed_offset INTEGER NOT NULL, payload TEXT NOT NULL, updated_at INTEGER NOT NULL)')
    await this.store.executeSql('CREATE TABLE IF NOT EXISTS checkpoints (transfer_id TEXT PRIMARY KEY, confirmed_offset INTEGER NOT NULL, digest TEXT, updated_at INTEGER NOT NULL)')
    await this.store.executeSql('CREATE TABLE IF NOT EXISTS artifacts (transfer_id TEXT PRIMARY KEY, staging_path TEXT, final_path TEXT, state TEXT NOT NULL, updated_at INTEGER NOT NULL)')
    await this.store.executeSql('CREATE TABLE IF NOT EXISTS diagnostic_events (event_id INTEGER PRIMARY KEY AUTOINCREMENT, transfer_id TEXT, code TEXT NOT NULL, message TEXT NOT NULL, created_at INTEGER NOT NULL)')
    await this.store.executeSql('CREATE TABLE IF NOT EXISTS app_state (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at INTEGER NOT NULL)')
  }
}
