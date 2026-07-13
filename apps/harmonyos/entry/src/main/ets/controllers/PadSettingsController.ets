import { common } from '@kit.AbilityKit'
import { BackgroundTransferService } from '../services/BackgroundTransferService'
import { PadPreferencesService } from '../services/PadPreferencesService'
import { errorText } from '../common/ErrorText'

/** 设置控制器只负责服务开关的事务语义，页面仍持有可观察状态。 */
export interface PadSettingsHost {
  receiverEnabled: boolean
  discoveryEnabled: boolean
  backgroundProtectionEnabled: boolean
  autoReceiveTrustedEnabled: boolean
  receiverReady: boolean
  statusText: string
  abilityContext(): common.UIAbilityContext
  startReceiverForSettings(): Promise<boolean>
  stopReceiverForSettings(): Promise<void>
  restartDiscoveryForSettings(): Promise<void>
  stopDiscoveryForSettings(): Promise<void>
  showToast(message: string): void
}

export class PadSettingsController {
  private host: PadSettingsHost
  private preferencesService: PadPreferencesService
  private backgroundService: BackgroundTransferService

  constructor(
    host: PadSettingsHost,
    preferencesService: PadPreferencesService,
    backgroundService: BackgroundTransferService,
  ) {
    this.host = host
    this.preferencesService = preferencesService
    this.backgroundService = backgroundService
  }

  setReceiverEnabled(enabled: boolean): void {
    this.host.receiverEnabled = enabled
    if (enabled) {
      this.host.startReceiverForSettings().then((ready: boolean) => {
        if (!ready) throw new Error('接收目录或监听服务未就绪')
        this.persist('receiverEnabled', true)
      }).catch((err: Error) => {
        this.host.receiverEnabled = false
        this.host.receiverReady = false
        this.persist('receiverEnabled', false)
        this.host.statusText = `接收服务启动失败：${errorText(err)}`
        this.host.showToast('接收服务启动失败，开关已恢复')
      })
      return
    }
    this.host.receiverReady = false
    this.host.statusText = '接收服务已关闭，仍可发现和发送'
    this.host.stopReceiverForSettings().then(() => {
      this.persist('receiverEnabled', false)
    }).catch((err: Error) => {
      this.host.receiverEnabled = true
      this.host.receiverReady = true
      this.persist('receiverEnabled', true)
      this.host.statusText = `接收服务关闭失败：${errorText(err)}`
      this.host.showToast('接收服务关闭失败，开关已恢复')
    })
  }

  setDiscoveryEnabled(enabled: boolean): void {
    this.host.discoveryEnabled = enabled
    const operation = enabled ? this.host.restartDiscoveryForSettings() : this.host.stopDiscoveryForSettings()
    if (!enabled) this.host.statusText = '自动发现已关闭，接收服务保持当前状态'
    operation.then(() => {
      this.persist('discoveryEnabled', enabled)
    }).catch((err: Error) => {
      this.host.discoveryEnabled = !enabled
      this.persist('discoveryEnabled', !enabled)
      this.host.statusText = `自动发现${enabled ? '启动' : '关闭'}失败：${errorText(err)}`
      this.host.showToast(`自动发现${enabled ? '启动' : '关闭'}失败，开关已恢复`)
    })
  }

  setBackgroundProtectionEnabled(enabled: boolean): void {
    this.host.backgroundProtectionEnabled = enabled
    this.backgroundService.setEnabled(enabled, this.host.abilityContext()).then(() => {
      this.persist('backgroundProtectionEnabled', enabled)
    }).catch((err: Error) => {
      this.host.backgroundProtectionEnabled = !enabled
      this.persist('backgroundProtectionEnabled', !enabled)
      this.host.statusText = `后台传输保护切换失败：${errorText(err)}`
      this.host.showToast('后台传输保护切换失败')
    })
  }

  setAutoReceiveTrustedEnabled(enabled: boolean): void {
    this.host.autoReceiveTrustedEnabled = enabled
    this.persist('autoReceiveTrustedEnabled', enabled)
  }

  private persist(key: string, value: boolean): void {
    this.preferencesService.saveBoolean(this.host.abilityContext(), key, value).catch((err: Error) => {
      this.host.statusText = `设置保存失败：${errorText(err)}`
    })
  }
}
