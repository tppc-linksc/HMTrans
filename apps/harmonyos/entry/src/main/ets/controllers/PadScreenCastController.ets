import { common } from '@kit.AbilityKit'
import { DeviceInfo } from '../common/Protocol'
import { errorText } from '../common/ErrorText'
import { PadPreferencesService } from '../services/PadPreferencesService'
import {
  CastResolution,
  CastNetworkTestState,
  CastSenderState,
  ScreenCastSenderService,
  castModeKey,
  supportedCastModes,
} from '../services/ScreenCastSenderService'
import {
  ScreenCastNetworkTestService,
} from '../services/ScreenCastNetworkTestService'

/** 投屏控制器所需的响应式页面状态与系统能力。 */
export interface PadScreenCastHost {
  castPortText: string
  castResolution: string
  castFrameRate: number
  supportedCastModes: Array<string>
  showCastSettings: boolean
  draftCastPort: string
  draftCastResolution: string
  draftCastFrameRate: number
  castState: CastSenderState
  castDetail: string
  castDeviceId: string
  castDeviceName: string
  castFps: number
  castBitrate: number
  castDroppedFrames: number
  networkTestState: CastNetworkTestState
  networkTestDetail: string
  selectedDeviceId: string
  deviceId: string
  identityFingerprint: string
  trustedSharedSecrets: Map<string, string>
  connectedDevices: Array<DeviceInfo>
  castPort: number

  abilityContext(): common.UIAbilityContext
  localDeviceName(): string
  runOnUi(task: () => void): void
  updateBackgroundTransferActivity(active: boolean): void
  showToast(message: string): void
}

/**
 * 管理一次 Pad 到 Mac 的投屏会话。页面只保存可观察状态，套接字、系统录屏与后台任务
 * 的生命周期集中在这里，避免主页面再次膨胀为网络控制器。
 */
export class PadScreenCastController {
  private host: PadScreenCastHost
  private preferencesService: PadPreferencesService
  private sender: ScreenCastSenderService = new ScreenCastSenderService()
  private networkTester: ScreenCastNetworkTestService = new ScreenCastNetworkTestService()
  private backgroundActive: boolean = false

  constructor(host: PadScreenCastHost, preferencesService: PadPreferencesService) {
    this.host = host
    this.preferencesService = preferencesService
  }

  async openSettings(): Promise<void> {
    this.host.draftCastPort = this.host.castPortText
    try {
      this.host.supportedCastModes = await supportedCastModes()
    } catch (err) {
      this.host.showToast(errorText(err))
      return
    }
    this.host.draftCastResolution = this.host.castResolution
    this.host.draftCastFrameRate = this.host.castFrameRate
    this.normalizeDraftMode()
    this.host.showCastSettings = true
  }

  async saveSettings(): Promise<void> {
    const port = Number(this.host.draftCastPort)
    if (!Number.isInteger(port) || port <= 0 || port > 65535) {
      this.host.showToast('投屏端口必须是 1 到 65535 之间的整数')
      return
    }
    const mode = castModeKey(this.host.draftCastResolution, this.host.draftCastFrameRate)
    if (this.host.supportedCastModes.indexOf(mode) < 0) {
      this.host.showToast('当前设备不支持所选分辨率与帧率组合')
      return
    }
    if (this.sender.isCasting()) await this.stop('投屏设置已更改')
    this.host.castPortText = `${port}`
    this.host.castResolution = this.host.draftCastResolution
    this.host.castFrameRate = this.host.draftCastFrameRate
    await this.preferencesService.saveCastSettings(
      this.host.abilityContext(), this.host.castPortText, this.host.castResolution, this.host.castFrameRate,
    )
    this.host.showCastSettings = false
    this.host.showToast('投屏设置已保存')
  }

  /** 只有双向在线且保存了 v0.3 配对密钥的 Mac 才能开始投屏。 */
  async start(device: DeviceInfo): Promise<void> {
    const connected = this.host.connectedDevices.some((item: DeviceInfo) => item.deviceId === device.deviceId)
    if (device.platform !== 'macOS' || !connected) {
      this.host.showToast('请先连接一台 Mac')
      return
    }
    const secret = this.host.trustedSharedSecrets.get(device.deviceId) ?? ''
    if (secret.length !== 64) {
      this.host.showToast('该设备由旧版本配对，请长按忘记设备后重新输入六位配对码')
      return
    }
    const capabilities = device.screenCastCapabilities ?? []
    if (device.screenCastProtocolVersion !== '0.3.0' || capabilities.indexOf('receive-h264') < 0 ||
      !device.screenCastPort || device.screenCastPort <= 0 || device.screenCastPort > 65535) {
      this.host.showToast('对方 Mac 未开启兼容的投屏接收服务')
      return
    }
    if (this.host.castState !== 'idle') await this.stop('切换投屏设备')
    let supported: Array<string>
    try {
      supported = await supportedCastModes()
    } catch (err) {
      this.host.showToast(errorText(err))
      return
    }
    const selectedMode = castModeKey(this.host.castResolution, this.host.castFrameRate)
    if (supported.indexOf(selectedMode) < 0) {
      this.host.showToast('当前设备不支持已保存的投屏参数，请在设置中重新选择')
      return
    }
    this.host.castDeviceId = device.deviceId
    this.host.castDeviceName = device.deviceName
    this.host.castState = 'connecting'
    this.host.castDetail = `正在连接 ${device.deviceName}`
    this.setBackgroundActive(true)
    try {
      await this.sender.start({
        host: device.ip, port: device.screenCastPort, deviceId: device.deviceId, deviceName: device.deviceName,
        localDeviceId: this.host.deviceId, localDeviceName: this.host.localDeviceName(),
        localFingerprint: this.host.identityFingerprint, sharedSecret: secret,
        resolution: this.host.castResolution as CastResolution,
        frameRate: this.host.castFrameRate,
      }, {
        onState: (state: CastSenderState, detail: string) => {
          if (state === 'idle' || state === 'failed') this.setBackgroundActive(false)
          this.host.runOnUi(() => { this.host.castState = state; this.host.castDetail = detail })
        },
        onStatistics: (fps: number, bitrate: number, droppedFrames: number) => {
          this.host.runOnUi(() => {
            this.host.castFps = fps
            this.host.castBitrate = bitrate
            this.host.castDroppedFrames = droppedFrames
          })
        },
      })
    } catch (err) {
      this.host.castState = 'failed'
      this.host.castDetail = errorText(err)
      this.setBackgroundActive(false)
      this.host.showToast(`投屏启动失败：${errorText(err)}`)
    }
  }

  async stop(reason: string = '用户停止投屏'): Promise<void> {
    await this.sender.stop(reason).catch(() => {})
    this.setBackgroundActive(false)
    this.host.castState = 'idle'
    this.host.castDetail = reason
    this.host.castDeviceId = ''
    this.host.castDeviceName = ''
    this.host.castFps = 0
    this.host.castBitrate = 0
    this.host.castDroppedFrames = 0
  }

  syncSnapshot(): void {
    this.host.castState = this.sender.currentState()
    this.host.castDetail = this.sender.currentDetail()
    this.host.castFps = this.sender.currentFps()
    this.host.castBitrate = this.sender.currentBitrate()
    this.host.castDroppedFrames = this.sender.currentDroppedFrames()
  }

  statisticsText(): string {
    if (this.host.castState !== 'casting') return ''
    return `${this.host.castFps} fps · ${(this.host.castBitrate / 1000000).toFixed(1)} Mbps · ` +
      `丢帧 ${this.host.castDroppedFrames}`
  }

  async runNetworkTest(): Promise<void> {
    if (this.host.networkTestState === 'running') {
      this.host.showToast('投屏网络测试正在进行中')
      return
    }
    if (this.host.castState !== 'idle' && this.host.castState !== 'failed') {
      this.host.showToast('请先停止投屏再进行网络测试')
      return
    }
    const candidates = this.host.connectedDevices.filter((item: DeviceInfo) =>
      item.platform === 'macOS' && item.screenCastProtocolVersion === '0.3.0' &&
      (item.screenCastCapabilities ?? []).indexOf('receive-h264') >= 0 &&
      item.screenCastPort !== undefined && item.screenCastPort > 0)
    const device = candidates.find((item: DeviceInfo) => item.deviceId === this.host.selectedDeviceId) ??
      (candidates.length === 1 ? candidates[0] : undefined)
    if (!device || !device.screenCastPort) {
      this.host.showToast(candidates.length > 1 ? '请先在连接页选择要测试的 Mac' : '暂无可测试的已连接 Mac')
      return
    }
    const secret = this.host.trustedSharedSecrets.get(device.deviceId) ?? ''
    if (secret.length !== 64) {
      this.host.showToast('该设备缺少 v0.3 配对密钥，请重新配对')
      return
    }
    this.host.networkTestState = 'running'
    this.host.networkTestDetail = `正在测试到 ${device.deviceName} 的延迟与上行吞吐`
    try {
      const result = await this.networkTester.run({
        host: device.ip, port: device.screenCastPort, deviceId: device.deviceId,
        localDeviceId: this.host.deviceId, localDeviceName: this.host.localDeviceName(),
        localFingerprint: this.host.identityFingerprint, sharedSecret: secret,
      })
      this.host.runOnUi(() => {
        this.host.networkTestState = 'completed'
        this.host.networkTestDetail = `${result.throughputMbps.toFixed(1)} Mbps · ` +
          `延迟 ${result.averageRttMs.toFixed(1)} ms · 抖动 ${result.jitterMs.toFixed(1)} ms · ` +
          result.recommendation
      })
      this.host.showToast('投屏网络测试完成')
    } catch (err) {
      this.host.runOnUi(() => {
        this.host.networkTestState = 'failed'
        this.host.networkTestDetail = errorText(err)
      })
      this.host.showToast(errorText(err))
    }
  }

  private setBackgroundActive(active: boolean): void {
    if (this.backgroundActive === active) return
    this.backgroundActive = active
    this.host.updateBackgroundTransferActivity(active)
  }

  private normalizeDraftMode(): void {
    const current = castModeKey(this.host.draftCastResolution, this.host.draftCastFrameRate)
    if (this.host.supportedCastModes.indexOf(current) >= 0) return
    const preferred: Array<string> = [
      castModeKey(this.host.draftCastResolution, 30),
      castModeKey('1080p', 60),
      castModeKey('1080p', 30),
      castModeKey('720p', 60),
      castModeKey('720p', 30),
      castModeKey('2k', 30),
      castModeKey('2k', 60),
    ]
    const fallback = preferred.find((mode: string) => this.host.supportedCastModes.indexOf(mode) >= 0) ??
      castModeKey('720p', 30)
    const parts = fallback.split('@')
    this.host.draftCastResolution = parts[0]
    this.host.draftCastFrameRate = Number(parts[1])
  }
}
