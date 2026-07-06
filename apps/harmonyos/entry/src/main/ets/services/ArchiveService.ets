import { common } from '@kit.AbilityKit'
import { zlib } from '@kit.BasicServicesKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { fileNameFromUri } from './FileHashService'

export interface SendableSource {
  uri: string
  displayName: string
  isArchive: boolean
  fileSize: number
  fileType: string
}

export class ArchiveService {
  async prepare(uri: string, context: common.UIAbilityContext): Promise<SendableSource> {
    if (!this.isDirectory(uri)) {
      const displayName = fileNameFromUri(uri)
      return {
        uri,
        displayName,
        isArchive: false,
        fileSize: this.safeFileSize(uri),
        fileType: this.fileTypeLabel(displayName),
      }
    }

    const archiveDir = `${context.cacheDir}/HMTrans`
    this.ensureDirectory(archiveDir)
    const baseName = fileNameFromUri(uri)
    const archivePath = `${archiveDir}/${baseName}-${Date.now()}.zip`
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
      displayName: `${baseName}.zip`,
      isArchive: true,
      fileSize: this.safeFileSize(archivePath),
      fileType: 'ZIP',
    }
  }

  private safeFileSize(uri: string): number {
    try {
      return fs.statSync(uri).size
    } catch (_) {
      return 0
    }
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
}
