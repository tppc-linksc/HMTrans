import { common } from '@kit.AbilityKit'
import { Environment, fileIo as fs, fileUri, picker } from '@kit.CoreFileKit'
import { fileShare } from '@kit.CoreFileKit'
import { errorText } from '../common/ErrorText'

/**
 * 接收目录的选取、授权保持与可写性检查。
 *
 * 公共下载目录依赖 FolderObtain 能力，只有平板、2in1 提供，手机没有；而手机上按绝对
 * 路径直写公共目录会被沙箱拒绝。要在两类设备上都落到用户可见的下载目录，正规做法是
 * 让用户用系统选择器指定一次目录，再用 fileShare 把授权持久化，之后每次启动激活即可。
 */
export class ReceiveDirectoryService {
  private publicDirectory: boolean = false

  /** 用户授权过的目录优先；否则平板走公共下载目录，手机退回应用目录保证功能可用。 */
  async prepare(context: common.UIAbilityContext, savedUri: string = ''): Promise<string> {
    const candidates: Array<string> = []
    const authorized = await this.activateSaved(savedUri)
    if (authorized.length > 0) candidates.push(authorized)
    if (canIUse('SystemCapability.FileManagement.File.Environment.FolderObtain')) {
      try { candidates.push(`${Environment.getUserDownloadDir()}/HMTrans`) } catch (_) {}
    }
    const privateDirectory = `${context.filesDir}/HMTrans/Received`
    candidates.push(privateDirectory)

    let lastError = ''
    for (const candidate of candidates) {
      // 目录已存在时 mkdir 会抛 File exists，不能据此判定不可用；
      // 唯一判据是 verify 的真实写入探测。
      try { fs.mkdirSync(candidate, true) } catch (_) {}
      try {
        this.verify(candidate)
        this.publicDirectory = candidate !== privateDirectory
        return candidate
      } catch (err) {
        lastError = errorText(err)
      }
    }
    throw new Error(`接收目录准备失败：${lastError}`)
  }

  /** 设置页用它区分文件管理器可见目录与应用内兜底目录。 */
  usesPublicDownloadDirectory(): boolean {
    return this.publicDirectory
  }

  /**
   * 让用户挑选接收目录并持久化授权，返回目录 URI。
   * 调用方负责保存 URI，下次启动交给 prepare 激活。
   */
  async chooseDirectory(context: common.UIAbilityContext): Promise<string> {
    const documentPicker = new picker.DocumentViewPicker(context)
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions()
    options.selectMode = picker.DocumentSelectMode.FOLDER
    options.maxSelectNumber = 1
    const selected = await documentPicker.select(options)
    if (selected.length === 0) throw new Error('未选择目录')
    const uri = selected[0]
    await fileShare.persistPermission([{ uri, operationMode: fileShare.OperationMode.READ_MODE |
      fileShare.OperationMode.WRITE_MODE }])
    return uri
  }

  /** 已保存的授权在每次冷启动后都需要重新激活，激活失败说明授权已失效。 */
  private async activateSaved(savedUri: string): Promise<string> {
    if (savedUri.length === 0) return ''
    try {
      await fileShare.activatePermission([{ uri: savedUri,
        operationMode: fileShare.OperationMode.READ_MODE | fileShare.OperationMode.WRITE_MODE }])
    } catch (_) {
      // 已激活或不支持重复激活时仍可继续，真正能否写入由 verify 决定。
    }
    try {
      return `${new fileUri.FileUri(savedUri).path}/HMTrans`
    } catch (_) {
      return ''
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
