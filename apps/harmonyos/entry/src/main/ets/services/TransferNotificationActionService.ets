import { common } from '@kit.AbilityKit'
import { TransferListItem, TransferState } from '../models/TransferListItem'

export interface TransferNotificationHost {
  currentTransfers: Array<TransferListItem>
  statusText: string
  runOnUi(task: () => void): void
  toggleTransferPause(item: TransferListItem): void
  cancelTransfer(item: TransferListItem): void
}

/** 将通知栏操作绑定到页面使用的同一份任务状态，并负责对称注销监听。 */
export class TransferNotificationActionService {
  private readonly host: TransferNotificationHost
  private registered: boolean = false
  private readonly handler: (action: string) => void

  constructor(host: TransferNotificationHost) {
    this.host = host
    this.handler = (action: string): void => this.handle(action)
  }

  register(context: common.UIAbilityContext): void {
    if (this.registered) return
    context.eventHub.on('hmtransTransferAction', this.handler)
    this.registered = true
  }

  unregister(context: common.UIAbilityContext): void {
    if (!this.registered) return
    context.eventHub.off('hmtransTransferAction', this.handler)
    this.registered = false
  }

  private handle(action: string): void {
    this.host.runOnUi(() => {
      if (action === 'pause_all') {
        const active = this.host.currentTransfers.filter((row: TransferListItem) =>
          row.state === TransferState.Active || row.state === TransferState.Preparing)
        const rows = active.length > 0 ? active : this.host.currentTransfers.filter((row: TransferListItem) =>
          row.state === TransferState.Paused || row.state === TransferState.Waiting)
        rows.forEach((row: TransferListItem) => this.host.toggleTransferPause(row))
        this.host.statusText = active.length > 0 ? '已从通知暂停全部活动任务' : '已从通知继续可恢复任务'
      } else if (action === 'cancel_all') {
        this.host.currentTransfers.slice().forEach((row: TransferListItem) => this.host.cancelTransfer(row))
        this.host.statusText = '已从通知取消全部任务，可恢复数据仍保留在私有目录'
      }
    })
  }
}
