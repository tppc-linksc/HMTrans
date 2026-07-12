import pasteboard from '@ohos.pasteboard'
import { deviceInfo } from '@kit.BasicServicesKit'
import { TransferStore } from '../persistence/TransferStore'

export interface PadDiagnosticSnapshot {
  receiverReady: boolean
  discoveryEnabled: boolean
  udpPort: number
  tcpPort: number
  nearbyCount: number
  currentCount: number
  historyCount: number
  status: string
}

/** Produces a support report while removing IP addresses and local paths. */
export class DiagnosticService {
  async copy(snapshot: PadDiagnosticSnapshot, store: TransferStore): Promise<void> {
    const errors = (await store.recentDiagnosticSummary()).map((value: string) => this.redact(value)).join('\n')
    const report = `HM互传诊断信息
应用版本：0.2.0
系统版本：${deviceInfo.osFullName}
接收服务：${snapshot.receiverReady ? '运行正常' : '已关闭或异常'}
自动发现：${snapshot.discoveryEnabled ? '已开启' : '已关闭'}
UDP/TCP：${snapshot.udpPort}/${snapshot.tcpPort}
发现设备：${snapshot.nearbyCount}
当前任务：${snapshot.currentCount}
历史记录：${snapshot.historyCount}
最近状态：${this.redact(snapshot.status)}
最近错误：
${errors.length > 0 ? errors : '无'}`
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData('text/plain', report))
    } catch (err) {
      throw new Error(`诊断信息写入剪贴板失败：${JSON.stringify(err)}`)
    }
  }

  private redact(value: string): string {
    return value.replace(/\b(?:\d{1,3}\.){3}\d{1,3}\b/g, '<local-ip>')
      .replace(/\/(?:Users|data|storage)\/[^\s,;]+/g, '<local-path>')
  }
}
