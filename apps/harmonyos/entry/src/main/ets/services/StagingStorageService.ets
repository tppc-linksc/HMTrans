import { fileIo as fs } from '@kit.CoreFileKit'

/** 仅匹配本项目实际创建的暂存产物，避免 transfer-1 误命中 transfer-10。 */
export function stagingEntryBelongsToTransfer(entryName: string, transferId: string): boolean {
  return entryName === transferId ||
    entryName === `${transferId}.part` ||
    entryName === `${transferId}.meta.json` ||
    entryName === `${transferId}-unpack` ||
    (entryName.startsWith(`${transferId}-`) && entryName.endsWith('.zip'))
}

/** 仅递归管理 HMTrans 应用私有暂存路径。 */
export class StagingStorageService {
  clear(path: string): void {
    this.removeRecursively(path)
    try {
      fs.mkdirSync(path, true)
    } catch (_) {
    }
  }

  removeRecursively(path: string): void {
    try {
      const stat = fs.statSync(path)
      if (!stat.isDirectory()) {
        fs.unlinkSync(path)
        return
      }
      fs.listFileSync(path).forEach((name: string) => {
        this.removeRecursively(`${path}/${name}`)
      })
      fs.rmdirSync(path)
    } catch (_) {
    }
  }

  /**
   * 超过保留期后删除已废弃的私有产物，同时保留仍在活动、暂停或等待恢复的任务。
   */
  pruneExpired(root: string, activeTransferIds: Array<string>, retentionMs: number): void {
    const cutoff = Date.now() - retentionMs
    this.pruneChildren(root, activeTransferIds, cutoff)
  }

  private pruneChildren(directory: string, activeTransferIds: Array<string>, cutoff: number): void {
    let names: Array<string> = []
    try {
      names = fs.listFileSync(directory)
    } catch (_) {
      return
    }
    names.forEach((name: string) => {
      const path = `${directory}/${name}`
      if (activeTransferIds.some((id: string) => stagingEntryBelongsToTransfer(name, id))) {
        return
      }
      try {
        const stat = fs.statSync(path)
        if (stat.isDirectory()) {
          this.pruneChildren(path, activeTransferIds, cutoff)
          const remaining = fs.listFileSync(path)
          if (remaining.length === 0 && stat.mtime < cutoff) {
            fs.rmdirSync(path)
          }
        } else if (stat.mtime < cutoff) {
          fs.unlinkSync(path)
        }
      } catch (_) {
      }
    })
  }
}
