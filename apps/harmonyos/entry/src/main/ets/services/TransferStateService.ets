import { completionDetail, nowText } from '../common/Formatters'
import { TransferListItem, TransferListItemOptions, TransferState } from '../models/TransferListItem'

export interface CompletionResult {
  current: Array<TransferListItem>
  historyItem?: TransferListItem
}

/** 将纯任务列表变更放在页面外部，使持久化时机清晰可见。 */
export class TransferStateService {
  upsert(current: Array<TransferListItem>, options: TransferListItemOptions, fallbackDeviceId: string): Array<TransferListItem> {
    const item = new TransferListItem(options)
    if (item.deviceId.length === 0) item.deviceId = fallbackDeviceId
    return [item].concat(current.filter((row: TransferListItem) => row.id !== options.id))
  }

  updateProgress(current: Array<TransferListItem>, id: string, progress: number, detail: string): void {
    const item = current.find((row: TransferListItem) => row.id === id)
    if (!item) return
    item.progress = progress; item.detail = detail
    item.confirmedOffset = Math.floor(item.fileSize * progress / 100); item.updatedAt = Date.now()
  }

  mark(current: Array<TransferListItem>, id: string, state: string, detail: string): void {
    const item = current.find((row: TransferListItem) => row.id === id)
    if (!item) return
    item.state = state; item.detail = detail; item.updatedAt = Date.now()
  }

  complete(current: Array<TransferListItem>, id: string, success: boolean, detail: string,
    localPath?: string, deviceId?: string): CompletionResult {
    const item = current.find((row: TransferListItem) => row.id === id)
    const remaining = current.filter((row: TransferListItem) => row.id !== id)
    if (!item) return { current: remaining }
    if (deviceId) item.deviceId = deviceId
    if (localPath) item.localPath = localPath
    return {
      current: remaining,
      historyItem: item.copyWith(success ? 100 : item.progress, completionDetail(detail, item),
        success ? TransferState.Done : TransferState.Failed, nowText()),
    }
  }

  appendHistory(history: Array<TransferListItem>, item: TransferListItem, deviceId: string): Array<TransferListItem> {
    const stored = item.copyWith(item.progress, item.detail, item.state, item.timeText)
    stored.deviceId = deviceId
    return [stored].concat(history.filter((row: TransferListItem) => row.id !== stored.id))
  }

  updateHistory(history: Array<TransferListItem>, id: string, detailPrefix: string): Array<TransferListItem> {
    return history.map((row: TransferListItem) => row.id === id ?
      row.copyWith(row.progress, completionDetail(detailPrefix, row), row.state, row.timeText) : row)
  }

  groupHistory(history: Array<TransferListItem>): Map<string, Array<TransferListItem>> {
    const groups: Map<string, Array<TransferListItem>> = new Map()
    history.forEach((item: TransferListItem) => {
      const key = item.deviceId.length > 0 ? item.deviceId : item.peerName
      groups.set(key, (groups.get(key) ?? []).concat([item]))
    })
    return groups
  }
}
