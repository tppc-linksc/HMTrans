import { common } from '@kit.AbilityKit'
import { zlib } from '@kit.BasicServicesKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { fileNameFromUri } from './FileHashService'

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

export class ArchiveService {
  /** A resumable outgoing task is valid only while its private staging copy exists. */
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

  /** Copies picker content into app-private storage before networking starts. */
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
      this.copyPickerSource(uri, stagedPath)
      return {
        uri: stagedPath,
        originalUri: uri,
        displayName,
        isArchive: false,
        fileSize: this.safeFileSize(stagedPath),
        fileType: this.fileTypeLabel(displayName),
        stagingOwned: true,
        sourceSize: this.safeFileSize(stagedPath),
        sourceFileCount: 1,
      }
    }

    const archiveDir = `${context.filesDir}/HMTrans/Staging/Archives`
    this.ensureDirectory(archiveDir)
    const baseName = fileNameFromUri(uri)
    const sourceSummary = this.directorySummary(uri)
    const archivePath = `${archiveDir}/${transferId}-${baseName}.zip`
    try {
      await zlib.compressFile(uri, archivePath, {
        level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION,
        memLevel: zlib.MemLevel.MEM_LEVEL_DEFAULT,
        strategy: zlib.CompressStrategy.COMPRESS_STRATEGY_DEFAULT_STRATEGY,
      })
    } catch (err) {
      throw new Error(`Unable to compress folder: ${JSON.stringify(err)}`)
    }

    return {
      uri: archivePath,
      originalUri: uri,
      // The archive is an internal payload; UI and history keep folder semantics.
      displayName: baseName,
      isArchive: true,
      fileSize: this.safeFileSize(archivePath),
      fileType: '文件夹',
      stagingOwned: true,
      sourceSize: sourceSummary.size,
      sourceFileCount: sourceSummary.count,
    }
  }

  /** Rebuilds a send source from a persisted task without reopening Picker URI. */
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
   * Picker URIs can lose their grant after the Picker closes or the app restarts.
   * Opening the URI while the grant is alive, then copying by file descriptor,
   * leaves networking and resume logic with a normal app-private file path.
   */
  private copyPickerSource(uri: string, stagedPath: string): void {
    const temporaryPath = `${stagedPath}.copying`
    let source: fs.File | undefined
    let target: fs.File | undefined
    try {
      try { fs.unlinkSync(temporaryPath) } catch (_) {}
      source = fs.openSync(uri, fs.OpenMode.READ_ONLY)
      target = fs.openSync(temporaryPath, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC)
      fs.copyFileSync(source.fd, target.fd)
      fs.closeSync(target)
      target = undefined
      fs.closeSync(source)
      source = undefined
      try { fs.unlinkSync(stagedPath) } catch (_) {}
      fs.renameSync(temporaryPath, stagedPath)
    } catch (err) {
      try { fs.unlinkSync(temporaryPath) } catch (_) {}
      throw new Error(`Unable to persist selected file: ${JSON.stringify(err)}`)
    } finally {
      if (target) try { fs.closeSync(target) } catch (_) {}
      if (source) try { fs.closeSync(source) } catch (_) {}
    }
  }

  private safeFileName(name: string): string {
    const sanitized = name.replace(/[\\/:*?"<>|]/g, '_').trim()
    if (sanitized.length === 0 || sanitized === '.' || sanitized === '..') {
      return `HMTrans-${Date.now()}`
    }
    return sanitized
  }

  private fileTypeLabel(fileName: string): string {
    const index = fileName.lastIndexOf('.')
    if (index < 0 || index === fileName.length - 1) {
      return '文件'
    }
    return fileName.substring(index + 1).toUpperCase()
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

  private directorySummary(root: string): DirectorySummary {
    let size = 0
    let count = 0
    const visit = (path: string): void => {
      fs.listFileSync(path).forEach((name: string) => {
        const child = `${path}/${name}`
        const stat = fs.statSync(child)
        if (stat.isDirectory()) {
          visit(child)
        } else {
          count += 1
          size += stat.size
        }
      })
    }
    visit(root)
    return { size, count }
  }
}
