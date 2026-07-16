import { DeviceInfo } from '../common/Protocol'
import { errorText } from '../common/ErrorText'
import { TransferListItem } from '../models/TransferListItem'
import { TransferStore } from '../persistence/TransferStore'
import { DiagnosticService } from '../services/DiagnosticService'

/** 诊断控制器只读取当前快照，不持有页面或网络资源。 */
export interface PadDiagnosticHost {
  receiverReady: boolean
  discoveryEnabled: boolean
  freshDevices: Array<DeviceInfo>
  currentTransfers: Array<TransferListItem>
  historyTransfers: Array<TransferListItem>
  statusText: string
  castState: string
  castDetail: string
  castFps: number
  castBitrate: number
  castDroppedFrames: number
  discoveryPort: number
  localTcpPort: number
  castPort: number
  transferStore: TransferStore

  showToast(message: string): void
}

/** 汇总诊断快照并统一处理剪贴板成功或失败反馈。 */
export class PadDiagnosticController {
  private host: PadDiagnosticHost
  private service: DiagnosticService = new DiagnosticService()

  constructor(host: PadDiagnosticHost) {
    this.host = host
  }

  copy(): void {
    const host = this.host
    this.service.copy({
      receiverReady: host.receiverReady, discoveryEnabled: host.discoveryEnabled,
      udpPort: host.discoveryPort, tcpPort: host.localTcpPort, nearbyCount: host.freshDevices.length,
      currentCount: host.currentTransfers.length, historyCount: host.historyTransfers.length, status: host.statusText,
      castPort: host.castPort, castState: host.castState, castDetail: host.castDetail,
      castFps: host.castFps, castBitrate: host.castBitrate, castDroppedFrames: host.castDroppedFrames,
    }, host.transferStore).then(() => {
      host.statusText = '诊断信息已复制'
      host.showToast('诊断信息已复制到剪贴板')
    }).catch((err: Error) => {
      host.statusText = `诊断信息复制失败：${errorText(err)}`
      host.showToast('诊断信息复制失败')
    })
  }
}
