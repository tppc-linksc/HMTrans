import { common } from '@kit.AbilityKit'
import { taskpool } from '@kit.ArkTS'
import { zlib } from '@kit.BasicServicesKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { fileNameFromUri, fileTypeLabel } from '../common/Formatters'
import { errorText } from '../common/ErrorText'

export interface SendableSource {
  uri: string
  originalUri: string
  displayName: string
  isArchive: boolean
  fileSize: number
  fileType: string
  stagingOwned: boolean
  sourceSize: number
  sourceFileCount: number
}

interface DirectorySummary {
  size: number
  count: number
}

@Concurrent
function copyPickerSourceTask(sourcePath: string, temporaryPath: string, stagedPath: string): void {
  let source: fs.File | undefined
  let target: fs.File | undefined
  try {
    try { fs.unlinkSync(temporaryPath) } catch (_) {}
    source = fs.openSync(sourcePath, fs.OpenMode.READ_ONLY)
    target = fs.openSync(temporaryPath, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC)
    fs.copyFileSync(source.fd, target.fd)
    fs.closeSync(target); target = undefined
    fs.closeSync(source); source = undefined
    try { fs.unlinkSync(stagedPath) } catch (_) {}
    fs.renameSync(temporaryPath, stagedPath)
  } catch (_) {
    throw new Error('Unable to copy selected file into staging storage')
  } finally {
    if (target) try { fs.closeSync(target) } catch (_) {}
    if (source) try { fs.closeSync(source) } catch (_) {}
  }
}

@Concurrent
function directorySummaryTask(root: string): Array<number> {
  let size = 0
  let count = 0
  const visit = (path: string): void => {
    fs.listFileSync(path).forEach((name: string) => {
      const child = `${path}/${name}`
      const stat = fs.statSync(child)
      if (stat.isDirectory()) visit(child)
      else { count += 1; size += stat.size }
    })
  }
  visit(root)
  return [size, count]
}

export class ArchiveService {
  /** 只有私有暂存副本仍存在时，发送任务才具备续传条件。 */
  sourceExists(path: string | undefined): boolean {
    if (!path || path.length === 0) return false
    try {
      return fs.accessSync(path)
    } catch (_) {
      return false
    }
  }

  removePrepared(source: SendableSource): void {
    try { fs.unlinkSync(source.uri) } catch (_) {}
    const parent = source.uri.substring(0, source.uri.lastIndexOf('/'))
    try { if (fs.listFileSync(parent).length === 0) fs.rmdirSync(parent) } catch (_) {}
  }

  /** 网络传输开始前，将 Picker 内容复制到应用私有存储。 */
  async prepare(uri: string, context: common.UIAbilityContext, transferId: string): Promise<SendableSource> {
    const appRoot = `${context.filesDir}/HMTrans`
    const stagingRoot = `${appRoot}/Staging`
    this.ensureDirectory(appRoot)
    this.ensureDirectory(stagingRoot)
    if (!this.isDirectory(uri)) {
      const displayName = this.safeFileName(fileNameFromUri(uri))
      const sourcesRoot = `${stagingRoot}/Sources`
      const transferRoot = `${sourcesRoot}/${transferId}`
      this.ensureDirectory(sourcesRoot)
      this.ensureDirectory(transferRoot)
      const stagedPath = `${transferRoot}/${displayName}`
      await this.copyPickerSource(uri, stagedPath)
      return {
        uri: stagedPath,
        originalUri: uri,
        displayName,
        isArchive: false,
        fileSize: this.safeFileSize(stagedPath),
        fileType: fileTypeLabel(displayName),
        stagingOwned: true,
        sourceSize: this.safeFileSize(stagedPath),
        sourceFileCount: 1,
      }
    }

    const archiveDir = `${context.filesDir}/HMTrans/Staging/Archives`
    this.ensureDirectory(archiveDir)
    const baseName = fileNameFromUri(uri)
    const sourceSummary = await this.directorySummary(uri)
    const archivePath = `${archiveDir}/${transferId}-${baseName}.zip`
    try {
      await zlib.compressFile(uri, archivePath, {
        level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION,
        memLevel: zlib.MemLevel.MEM_LEVEL_DEFAULT,
        strategy: zlib.CompressStrategy.COMPRESS_STRATEGY_DEFAULT_STRATEGY,
      })
    } catch (err) {
      throw new Error(`Unable to compress folder: ${errorText(err)}`)
    }

    return {
      uri: archivePath,
      originalUri: uri,
      // 归档只是内部载荷，界面和历史记录仍保留文件夹语义。
      displayName: baseName,
      isArchive: true,
      fileSize: this.safeFileSize(archivePath),
      fileType: '文件夹',
      stagingOwned: true,
      sourceSize: sourceSummary.size,
      sourceFileCount: sourceSummary.count,
    }
  }

  /** 从持久化任务重建发送源，无需重新打开 Picker URI。 */
  restore(stagingPath: string, originalUri: string | undefined, displayName: string,
    fileSize: number, fileType: string, sourceSize?: number, sourceFileCount?: number): SendableSource {
    if (!this.sourceExists(stagingPath)) {
      throw new Error('Persistent staging source is missing')
    }
    const actualSize = this.safeFileSize(stagingPath)
    return {
      uri: stagingPath,
      originalUri: originalUri ?? stagingPath,
      displayName,
      isArchive: fileType === '文件夹' || stagingPath.toLowerCase().endsWith('.zip'),
      fileSize: actualSize,
      fileType,
      stagingOwned: true,
      sourceSize: sourceSize ?? actualSize,
      sourceFileCount: sourceFileCount ?? (fileType === '文件夹' ? 0 : 1),
    }
  }

  private safeFileSize(uri: string): number {
    try {
      return fs.statSync(uri).size
    } catch (_) {
      return 0
    }
  }

  /**
   * Picker 关闭或应用重启后，Picker URI 可能失去授权。
   * 在授权有效时打开 URI 并通过文件描述符复制，网络与续传逻辑即可使用普通的应用私有路径。
   */
  private async copyPickerSource(uri: string, stagedPath: string): Promise<void> {
    const temporaryPath = `${stagedPath}.copying`
    try {
      await taskpool.execute(copyPickerSourceTask, uri, temporaryPath, stagedPath)
    } catch (err) {
      try { fs.unlinkSync(temporaryPath) } catch (_) {}
      throw new Error(`Unable to persist selected file: ${errorText(err)}`)
    }
  }

  private safeFileName(name: string): string {
    const sanitized = name.replace(/[\\/:*?"<>|]/g, '_').trim()
    if (sanitized.length === 0 || sanitized === '.' || sanitized === '..') {
      return `HMTrans-${Date.now()}`
    }
    return sanitized
  }

  private isDirectory(uri: string): boolean {
    try {
      const stat = fs.statSync(uri)
      return stat.isDirectory()
    } catch (_) {
      return false
    }
  }

  private ensureDirectory(path: string): void {
    try {
      fs.mkdirSync(path)
    } catch (_) {
    }
  }

  private async directorySummary(root: string): Promise<DirectorySummary> {
    try {
      const values = await taskpool.execute(directorySummaryTask, root) as Array<number>
      return { size: values[0] ?? 0, count: values[1] ?? 0 }
    } catch (err) {
      throw new Error(`Unable to inspect selected folder: ${errorText(err)}`)
    }
  }
}
