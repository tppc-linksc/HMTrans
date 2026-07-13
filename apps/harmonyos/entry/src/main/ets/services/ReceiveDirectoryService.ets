import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit'
import { Environment, fileIo as fs } from '@kit.CoreFileKit'
import { errorText } from '../common/ErrorText'

const DOWNLOAD_PERMISSION: Permissions = 'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY'

/** Owns permission and writability checks for the single public destination. */
export class ReceiveDirectoryService {
  async prepare(context: common.UIAbilityContext): Promise<string> {
    try {
      const manager = abilityAccessCtrl.createAtManager()
      const result = await manager.requestPermissionsFromUser(context, [DOWNLOAD_PERMISSION])
      if (result.authResults.length === 0 || result.authResults[0] !== 0) {
        throw new Error('未授权下载目录')
      }
      if (!canIUse('SystemCapability.FileManagement.UserFileService')) {
        throw new Error('当前设备不支持下载目录能力')
      }
      const directory = `${Environment.getUserDownloadDir()}/HMTrans`
      try { fs.mkdirSync(directory) } catch (_) {}
      this.verify(directory)
      return directory
    } catch (err) {
      throw new Error(`下载目录准备失败：${errorText(err)}`)
    }
  }

  verify(directory: string): void {
    const testPath = `${directory}/.hmtrans-write-test`
    let file: fs.File | undefined
    try {
      file = fs.openSync(testPath, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE)
    } catch (err) {
      throw new Error(`接收目录不可写：${errorText(err)}`)
    } finally {
      if (file) try { fs.closeSync(file) } catch (_) {}
      try { fs.unlinkSync(testPath) } catch (_) {}
    }
  }
}
