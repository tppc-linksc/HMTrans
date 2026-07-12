import { fileIo as fs } from '@kit.CoreFileKit'

/** Recursively manages only HMTrans app-private staging paths. */
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
   * Removes abandoned private artifacts after the retention window while
   * preserving every task that is still active, paused, or waiting to resume.
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
      if (activeTransferIds.some((id: string) => path.indexOf(id) >= 0)) {
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
