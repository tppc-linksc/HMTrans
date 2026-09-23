import { common } from '@kit.AbilityKit'
import { errorText } from '../common/ErrorText'
import { TransferListItem } from '../models/TransferListItem'
import { TransferStore } from '../persistence/TransferStore'
import { OutgoingTransferCoordinator } from '../services/OutgoingTransferCoordinator'
import { ReceiveDirectoryService } from '../services/ReceiveDirectoryService'
import { StagingStorageService } from '../services/StagingStorageService'
import { TcpTransferService } from '../services/TcpTransferService'

/** 临时空间与下载目录检查所需的最小页面能力。 */
export interface PadStorageHost {
  receiveDirectory: string
  statusText: string
  currentTransfers: Array<TransferListItem>
  activeTransferDeviceIds: Map<string, string>

  abilityContext(): common.UIAbilityContext
  prepareReceiveDirectory(context: common.UIAbilityContext): Promise<void>
  persistTransferState(immediate?: boolean): void
  showToast(message: string): void
}

/** 将可能等待网络与文件系统的设置操作移出主页面。 */
export class PadStorageController {
  private host: PadStorageHost
  private transferService: TcpTransferService
  private outgoingCoordinator: OutgoingTransferCoordinator
  private stagingService: StagingStorageService
  private directoryService: ReceiveDirectoryService
  private transferStore: TransferStore

  constructor(
    host: PadStorageHost,
    transferService: TcpTransferService,
    outgoingCoordinator: OutgoingTransferCoordinator,
    stagingService: StagingStorageService,
    directoryService: ReceiveDirectoryService,
    transferStore: TransferStore,
  ) {
    this.host = host
    this.transferService = transferService
    this.outgoingCoordinator = outgoingCoordinator
    this.stagingService = stagingService
    this.directoryService = directoryService
    this.transferStore = transferStore
  }

  async clearTemporaryStorage(): Promise<void> {
    const stagingDir = `${this.host.abilityContext().filesDir}/HMTrans/Staging`
    this.host.statusText = '正在停止未完成任务'
    this.outgoingCoordinator.cancelAll()
    this.host.currentTransfers.forEach((item: TransferListItem) => this.transferService.cancelTransfer(item.id))
    const idle = await Promise.all([this.transferService.waitForIdle(), this.outgoingCoordinator.waitForIdle()])
    if (!idle[0] || !idle[1]) throw new Error('仍有传输正在释放资源，请稍后重试')
    this.host.currentTransfers = []
    this.host.activeTransferDeviceIds.clear()
    this.stagingService.clear(stagingDir)
    this.host.persistTransferState(true)
    this.host.statusText = '临时传输空间和未完成任务已清除'
    this.host.showToast('临时传输空间已清除')
  }

  /** 重新选取接收目录，并用无残留的探测验证目录可写。 */
  async checkReceiveDirectory(): Promise<void> {
    try {
      if (this.host.receiveDirectory.length === 0) {
        await this.host.prepareReceiveDirectory(this.host.abilityContext())
        if (this.host.receiveDirectory.length === 0) {
          this.host.showToast('接收目录不可用，请查看状态说明')
          return
        }
      }
      this.directoryService.verify(this.host.receiveDirectory)
      this.host.statusText = `接收目录可用：${this.host.receiveDirectory}`
      this.host.showToast(this.host.statusText)
    } catch (err) {
      this.transferStore.recordDiagnostic('STO-DIR-001', errorText(err)).catch(() => {})
      this.host.statusText = `接收目录不可写：${errorText(err)}`
      this.host.showToast('接收目录不可写')
    }
  }
}
