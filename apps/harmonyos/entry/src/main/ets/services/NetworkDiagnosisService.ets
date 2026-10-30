import { socket } from '@kit.NetworkKit'
import { wifiManager } from '@kit.ConnectivityKit'
import { errorText } from '../common/ErrorText'
import { DiscoveryStats } from './DiscoveryService'

export interface NetworkDiagnosisInput {
  localIp: string
  discoveryPort: number
  targetIp: string
  targetPort: number
  stats: DiscoveryStats
}

/**
 * 体检结论直接对应现场可执行的判断，不做无法验证的推断：
 * 「发出去了但一条没收到」＝链路或广播被丢；「2.4G + 弱信号」＝建议切 5G。
 */
export interface NetworkDiagnosisReport {
  level: string
  title: string
  lines: Array<string>
  advice: string
}

const HANDSHAKE_TIMEOUT_MS: number = 1200
const WEAK_SIGNAL_DBM: number = -70
const SLOW_HANDSHAKE_MS: number = 300

/** 汇总 Wi-Fi 频段、发现报文收发和对端握手耗时，用来解释「为什么看不到设备」。 */
export class NetworkDiagnosisService {
  async run(input: NetworkDiagnosisInput): Promise<NetworkDiagnosisReport> {
    const lines: Array<string> = []
    let band: number = 0
    let channel: number = 0
    let rssi: number = 0
    let linkSpeed: number = 0
    let ssid: string = ''
    let connected: boolean = false

    try {
      const info = await wifiManager.getLinkedInfo()
      ssid = info.ssid.length > 0 ? info.ssid : '未命名网络'
      band = info.band
      rssi = info.rssi
      linkSpeed = info.linkSpeed
      if (info.frequency > 0) {
        channel = info.frequency > 3000 ? Math.round((info.frequency - 5000) / 5)
          : Math.round((info.frequency - 2407) / 5)
        if (band !== 1 && band !== 2) {
          band = info.frequency > 3000 ? 2 : 1
        }
      }
      connected = true
    } catch (err) {
      lines.push(`Wi-Fi：读取失败（${errorText(err as Error)}）`)
    }

    if (connected) {
      lines.push(`Wi-Fi：${ssid} · ${this.bandText(band)}${channel > 0 ? ` · 信道 ${channel}` : ''}`)
      lines.push(`信号：${rssi} dBm · 协商速率 ${linkSpeed} Mbps`)
    }
    if (input.localIp.length > 0) {
      lines.push(`本机地址：${input.localIp} · 发现端口 UDP ${input.discoveryPort}`)
    }

    const stats = input.stats
    const failedText = stats.failedBeacons > 0 ? `（失败 ${stats.failedBeacons} 条）` : ''
    lines.push(`发现报文：已发出 ${stats.sentBeacons} 条${failedText} · 收到对端 ${stats.receivedPackets} 条`)
    lines.push(`最近收到对端报文：${this.ageText(stats.lastReceivedAt)}`)
    if (stats.lastError.length > 0) {
      lines.push(`最近发送错误：${stats.lastError}`)
    }

    const handshake = await this.handshakeMs(input.targetIp, input.targetPort)
    if (this.isUsableAddress(input.targetIp)) {
      lines.push(handshake >= 0 ? `与对端握手：${handshake} ms（TCP ${input.targetPort}）` : '与对端握手：不可达')
    } else {
      lines.push('与对端握手：尚未保存对端地址，选择设备后可重测')
    }

    return this.conclude(band, rssi, handshake, stats, lines)
  }

  private conclude(
    band: number, rssi: number, handshake: number, stats: DiscoveryStats, lines: Array<string>,
  ): NetworkDiagnosisReport {
    if (stats.sentBeacons === 0 && stats.receivedPackets === 0) {
      return {
        level: 'warn',
        title: '自动发现没有在运行',
        lines: lines,
        advice: '本机还没发出过任何发现报文。请回到设置确认「自动发现」已开启，' +
          '并确认应用在前台；锁屏或切到后台时 HarmonyOS 会挂起广播定时器。',
      }
    }
    if (!stats.lastReceivedAt && stats.sentBeacons > 0) {
      return {
        level: 'bad',
        title: '已发出广播，但收不到任何对端报文',
        lines: lines,
        advice: '两台设备可能不在同一网段，或路由器开启了 AP 隔离/无线设备隔离。' +
          '先在路由器后台关闭「AP 隔离」，再确认双端连的是同一个频段。' +
          '如果手机在 2.4GHz、电脑在 5GHz，部分光猫不会转发跨频段的广播。',
      }
    }
    if (band === 1 && (rssi <= WEAK_SIGNAL_DBM || handshake > SLOW_HANDSHAKE_MS)) {
      return {
        level: 'warn',
        title: '当前在 2.4GHz，链路质量偏弱',
        lines: lines,
        advice: '2.4GHz 只有 1/6/11 三个互不重叠信道，容易被邻居 AP 挤占；' +
          '实测该环境下会出现秒级延迟和丢包，发现报文会被整批丢弃。' +
          '建议把双端都切到 5GHz，或把路由器 2.4GHz 信道固定为 1 或 11、带宽 20MHz。',
      }
    }
    if (handshake > SLOW_HANDSHAKE_MS) {
      return {
        level: 'warn',
        title: '连接握手偏慢',
        lines: lines,
        advice: '对端可达但握手耗时偏高，通常是无线空口拥塞或对端处于省电状态。' +
          '可先让对端保持亮屏再测一次；仍然偏慢时建议改用 5GHz 或网线。',
      }
    }
    return {
      level: 'good',
      title: '链路检查通过',
      lines: lines,
      advice: '本机 Wi-Fi 与发现报文都正常。如果此时仍看不到设备，请在对端运行一次体检，' +
        '对比两侧的「已发出/已收到」计数，就能判断是哪一侧的报文没有送达。',
    }
  }

  private bandText(band: number): string {
    if (band === 2) return '5GHz'
    if (band === 1) return '2.4GHz'
    return '频段未知'
  }

  private ageText(timestamp: number): string {
    if (timestamp <= 0) return '从未收到'
    const seconds = Math.floor((Date.now() - timestamp) / 1000)
    if (seconds < 1) return '刚刚'
    if (seconds < 60) return `${seconds} 秒前`
    return `${Math.floor(seconds / 60)} 分钟前`
  }

  /** 用 TCP 握手耗时近似链路往返质量；失败返回 -1，不区分具体原因。 */
  private async handshakeMs(host: string, port: number): Promise<number> {
    if (!this.isUsableAddress(host) || port <= 0 || port > 65535) {
      return -1
    }
    const client = socket.constructTCPSocketInstance()
    const started = Date.now()
    try {
      await client.connect({
        address: { address: host, port: port, family: 1 },
        timeout: HANDSHAKE_TIMEOUT_MS,
      })
      return Date.now() - started
    } catch (_) {
      return -1
    } finally {
      await client.close().catch(() => {
      })
    }
  }

  private isUsableAddress(value: string): boolean {
    if (!value || value.length === 0 || value === '0.0.0.0' || value === '127.0.0.1') {
      return false
    }
    return /^\d{1,3}(\.\d{1,3}){3}$/.test(value)
  }
}
