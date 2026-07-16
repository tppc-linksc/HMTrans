import { common } from '@kit.AbilityKit'
import { preferences } from '@kit.ArkData'
import { DEFAULT_PORT, DISCOVERY_PORT, DeviceInfo, FileMeta } from '../common/Protocol'
import { nowText } from '../common/Formatters'
import { TransferListItem, TransferListItemOptions, TransferState } from '../models/TransferListItem'
import { PadConnectionPage } from '../components/ConnectionPage'
import { TransferHistoryPage } from '../components/TransferHistoryPage'
import { PadSettingsPage } from '../components/SettingsPage'
import { BottomDock } from '../components/BottomDock'
import { PadPrivacyBlankPage } from '../components/PrivacyBlankPage'
import { DeviceNameEditorOverlay, PairingOverlay, PortEditorOverlay, PrivacyConsentOverlay } from '../components/AppOverlays'
import { ArchiveService, SendableSource } from '../services/ArchiveService'
import { BackgroundTransferService } from '../services/BackgroundTransferService'
import { StagingStorageService } from '../services/StagingStorageService'
import { DiscoveryService } from '../services/DiscoveryService'
import { TcpTransferService } from '../services/TcpTransferService'
import { DropUriService } from '../services/DropUriService'
import { ReceiveDirectoryService } from '../services/ReceiveDirectoryService'
import { PadPreferencesService } from '../services/PadPreferencesService'
import { TransferStateService } from '../services/TransferStateService'
import { OutgoingTransferCoordinator } from '../services/OutgoingTransferCoordinator'
import { DiagnosticService } from '../services/DiagnosticService'
import { NetworkChangeService } from '../services/NetworkChangeService'
import { PadDialogService } from '../services/PadDialogService'
import { DeviceIdentityService } from '../services/DeviceIdentityService'
import { TransferNotificationActionService } from '../services/TransferNotificationActionService'
import { TransferSnapshot, TransferStore } from '../persistence/TransferStore'
import { errorText } from '../common/ErrorText'
import { PadTransferController } from '../controllers/PadTransferController'
import { PadNetworkController } from '../controllers/PadNetworkController'
import { PadSettingsController } from '../controllers/PadSettingsController'

const DEVICE_TTL_MS: number = 12000
const PREFERENCES_NAME: string = 'HMTrans'
const PRIVACY_ACCEPTED_KEY: string = 'privacyAccepted'
const PRIVACY_ACCEPTED_VERSION_KEY: string = 'privacyAcceptedVersion'
const PRIVACY_VERSION: string = '2026-07-13'
const PRIVACY_POLICY_URL: string = 'https://hmt.tppc.top/privacy.html'

@Entry
@ComponentV2
struct Index {
  // 这里只保留响应式界面状态；文件、网络和存储工作由下层服务负责。
  @Local targetIp: string = ''
  @Local portText: string = `${DEFAULT_PORT}`
  @Local localTcpPortText: string = `${DEFAULT_PORT}`
  @Local discoveryPortText: string = `${DISCOVERY_PORT}`
  @Local statusText: string = '正在启动 HM互传'
  @Local nearbyDevices: Array<DeviceInfo> = []
  @Local selectedDeviceId: string = ''
  @Local selectedDeviceIds: Array<string> = []
  @Local trustedDeviceIds: Array<string> = []
  @Local persistedDevices: Array<DeviceInfo> = []
  @Local currentTransfers: Array<TransferListItem> = []
  @Local historyTransfers: Array<TransferListItem> = []
  @Local activePage: string = 'connection'
  @Local historyFilter: string = 'all'
  @Local networkName: string = '正在获取网络名称'
  @Local localIp: string = ''
  @Local localDeviceDisplayName: string = ''
  @Local customDeviceDisplayName: string = ''
  @Local receiverEnabled: boolean = true
  @Local discoveryEnabled: boolean = true
  @Local backgroundProtectionEnabled: boolean = true
  @Local autoReceiveTrustedEnabled: boolean = true
  @Local pairingCode: string = '000 000'
  @Local pairingSeconds: number = 180
  @Local pairingTarget: DeviceInfo | undefined = undefined
  @Local pairingInput: string = ''
  @Local showPortEditor: boolean = false
  @Local showDeviceNameEditor: boolean = false
  @Local draftDeviceName: string = ''
  @Local draftUdpPort: string = `${DISCOVERY_PORT}`
  @Local draftTcpPort: string = `${DEFAULT_PORT}`
  @Local compactLayout: boolean = false
  @Local showPrivacyConsentDialog: boolean = false
  @Local contentUnlocked: boolean = false
  transferService: TcpTransferService = new TcpTransferService()
  transferStore: TransferStore = new TransferStore()
  archiveService: ArchiveService = new ArchiveService()
  private backgroundTransferService: BackgroundTransferService = new BackgroundTransferService()
  private stagingStorageService: StagingStorageService = new StagingStorageService()
  private dropUriService: DropUriService = new DropUriService()
  private receiveDirectoryService: ReceiveDirectoryService = new ReceiveDirectoryService()
  private padPreferencesService: PadPreferencesService = new PadPreferencesService()
  private transferStateService: TransferStateService = new TransferStateService()
  private outgoingCoordinator: OutgoingTransferCoordinator =
    new OutgoingTransferCoordinator(this.transferService, this.archiveService)
  private diagnosticService: DiagnosticService = new DiagnosticService()
  private networkChangeService: NetworkChangeService = new NetworkChangeService()
  private dialogService: PadDialogService = new PadDialogService()
  private deviceIdentityService: DeviceIdentityService = new DeviceIdentityService()
  private notificationActionService: TransferNotificationActionService =
    new TransferNotificationActionService(this)
  private settingsController: PadSettingsController =
    new PadSettingsController(this, this.padPreferencesService, this.backgroundTransferService)
  discoveryService?: DiscoveryService
  private bootstrapped: boolean = false
  private pageActive: boolean = false
  private privacyAccepted: boolean = false
  private privacyConsentResolver?: (agreed: boolean) => void
  deviceId: string = ''
  identityFingerprint: string = ''
  trustedFingerprints: Map<string, string> = new Map()
  deviceLastSeenAt: Map<string, number> = new Map()
  confirmedDeviceLastSeenAt: Map<string, number> = new Map()
  activeTransferDeviceIds: Map<string, string> = new Map()
  receiveDirectory: string = ''
  receiverReady: boolean = false
  pruneTimer?: number
  pairingTimer?: number
  persistenceTimer?: number
  private transferController?: PadTransferController
  private networkController?: PadNetworkController

  aboutToAppear(): void {
    this.pageActive = true
    if (this.bootstrapped) {
      return
    }
    this.transferController = new PadTransferController(
      this, this.transferService, this.transferStore, this.archiveService, this.stagingStorageService,
      this.dropUriService, this.transferStateService, this.outgoingCoordinator,
    )
    this.networkController = new PadNetworkController(this)
    this.bootstrapped = true
    this.bootstrap()
  }

  onPageShow(): void {
    this.pageActive = true
    if (!this.bootstrapped || !this.privacyAccepted) {
      return
    }
    this.notificationActionService.register(this.abilityContext())
    this.network().startDevicePruning()
    this.networkChangeService.start(() => this.network().handleNetworkChanged())
    this.statusText = this.selectedDevice ? this.statusText : '正在重新发现设备'
    this.network().refreshNetworkName()
    this.network().ensureReceiverAndDiscovery().catch((err: Error) => {
      this.statusText = `服务恢复失败：${errorText(err)}`
    })
  }

  aboutToDisappear(): void {
    this.pageActive = false
    this.network().clearLifecycleTimers()
    this.transfers().clearLifecycleTimers()
    this.notificationActionService.unregister(this.abilityContext())
    this.networkChangeService.stop()
    this.persistTransferState(true)
    this.network().stopDiscovery().catch(() => {})
    this.transferService.stopReceive().catch(() => {})
  }

  build() {
    Stack() {
      if (this.contentUnlocked) {
        this.MainLayout()
      } else {
        PadPrivacyBlankPage()
      }
      if (this.showPrivacyConsentDialog) {
        PrivacyConsentOverlay({
          onOpenPolicy: () => this.openPrivacyPolicy(),
          onResolve: (agreed: boolean) => this.resolvePrivacyConsent(agreed),
        })
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private MainLayout() {
    Stack({ alignContent: Alignment.Bottom }) {
      Scroll() {
        this.PageContent()
      }
      .width('100%')
      .height('100%')
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Off)
      .backgroundColor($r('app.color.app_background'))
      .padding({ bottom: 92 })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .onAreaChange((_oldArea, newArea) => {
        const width = Number.parseFloat(`${newArea.width}`)
        this.compactLayout = Number.isFinite(width) && width < 760
      })

      BottomDock({ activePage: this.activePage, onPageChanged: (page: string) => { this.activePage = page } })
      if (this.pairingTarget) {
        PairingOverlay({
          deviceName: this.pairingTarget.deviceName,
          input: this.pairingInput,
          onInputChanged: (value: string) => { this.pairingInput = value },
          onCancel: () => { this.pairingTarget = undefined; this.pairingInput = '' },
          onSubmit: () => this.network().submitPairing(),
        })
      }
      if (this.showDeviceNameEditor) {
        DeviceNameEditorOverlay({
          name: this.draftDeviceName,
          onNameChanged: (value: string) => { this.draftDeviceName = value },
          onCancel: () => { this.showDeviceNameEditor = false },
          onSave: () => { this.saveDeviceName() },
        })
      }
      if (this.showPortEditor) {
        PortEditorOverlay({
          udpPort: this.draftUdpPort,
          tcpPort: this.draftTcpPort,
          onUdpChanged: (value: string) => { this.draftUdpPort = value },
          onTcpChanged: (value: string) => { this.draftTcpPort = value },
          onCancel: () => { this.showPortEditor = false },
          onSave: () => {
            this.localTcpPortText = this.draftTcpPort
            this.discoveryPortText = this.draftUdpPort
            this.showPortEditor = false
            this.applyNetworkPorts()
          },
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  private PageContent() {
    Column({ space: 18 }) {
      // 三个主页面常驻组件树，只切换可见性；避免每次点击 Dock 都销毁并重建
      // 设备卡片、历史列表和设置控件，从而减少切页时的主线程抖动。
      Stack({ alignContent: Alignment.TopStart }) {
        Column() {
          this.ConnectionPage()
        }
        .width('100%')
        .visibility(this.activePage === 'connection' ? Visibility.Visible : Visibility.None)

        Column() {
          this.TransferPage()
        }
        .width('100%')
        .visibility(this.activePage === 'history' ? Visibility.Visible : Visibility.None)

        Column() {
          this.SettingsPage()
        }
        .width('100%')
        .visibility(this.activePage === 'settings' ? Visibility.Visible : Visibility.None)
      }
      .width('100%')
    }
    .width('100%')
    .constraintSize({ minHeight: '100%' })
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.Start)
    .padding({ left: this.compactLayout ? 18 : 30, right: this.compactLayout ? 18 : 30, top: 52, bottom: 28 })
  }

  @Builder
  private ConnectionPage() {
    PadConnectionPage({
      compactLayout: this.compactLayout,
      networkName: this.networkName,
      localIp: this.localIp,
      udpPort: this.discoveryPort,
      tcpPort: this.localTcpPort,
      pairingCode: this.pairingCode,
      pairingSeconds: this.pairingSeconds,
      connectedDevices: this.connectedDevices,
      offlineDevices: this.offlineDevices,
      unpairedDevices: this.unpairedDevices,
      selectedDeviceIds: this.selectedDeviceIds,
      onRegenerateCode: () => this.regeneratePairingCode(),
      onPairDevice: (device: DeviceInfo) => this.network().beginPairing(device),
      onReconnectDevice: (device: DeviceInfo) => this.network().reconnectTrustedDevice(device),
      onToggleTarget: (device: DeviceInfo) => this.network().toggleTransferTarget(device),
      onForgetDevice: (device: DeviceInfo) => this.confirmForgetDevice(device),
      selectedDeviceName: this.transferTargetLabel(),
      onSelectFile: () => { this.selectAndSendFile() },
      onFilesDropped: (event: DragEvent) => this.handleDrop(event),
    })
  }

  @Builder
  private TransferPage() {
    TransferHistoryPage({
      currentTransfers: this.currentTransfers,
      historyTransfers: this.historyTransfers,
      historyFilter: this.historyFilter,
      compactLayout: this.compactLayout,
      onFilterChanged: (value: string) => { this.historyFilter = value },
      onTogglePause: (item: TransferListItem) => this.toggleTransferPause(item),
      onCancel: (item: TransferListItem) => this.confirmCancelTransfer(item),
      onToggleGroup: (item: TransferListItem) => this.toggleTransferGroup(item),
      onCancelGroup: (item: TransferListItem) => this.confirmCancelTransferGroup(item),
      onDeleteHistory: (item: TransferListItem) => this.confirmDeleteHistoryItem(item),
      onRetryHistory: (item: TransferListItem) => this.retryHistoryItem(item),
      onClearPeer: (deviceKey: string, peerName: string) => this.confirmClearHistoryPeer(deviceKey, peerName),
      onClearAll: () => this.confirmClearAllHistory(),
    })
  }

  @Builder
  private SettingsPage() {
    PadSettingsPage({
      receiverEnabled: this.receiverEnabled,
      discoveryEnabled: this.discoveryEnabled,
      backgroundProtectionEnabled: this.backgroundProtectionEnabled,
      autoReceiveTrustedEnabled: this.autoReceiveTrustedEnabled,
      udpPort: this.discoveryPort,
      tcpPort: this.localTcpPort,
      networkServiceReady: this.receiverReady && this.discoveryEnabled,
      downloadDirectoryReady: this.receiveDirectory.length > 0,
      deviceName: this.localDeviceName(),
      onReceiverChanged: (enabled: boolean) => this.settingsController.setReceiverEnabled(enabled),
      onDiscoveryChanged: (enabled: boolean) => this.settingsController.setDiscoveryEnabled(enabled),
      onBackgroundChanged: (enabled: boolean) => this.settingsController.setBackgroundProtectionEnabled(enabled),
      onAutoReceiveChanged: (enabled: boolean) => this.settingsController.setAutoReceiveTrustedEnabled(enabled),
      onCheckDownload: () => { this.checkReceiveDirectory() },
      onClearStaging: () => this.confirmClearHistory(),
      onEditPorts: () => this.openPortEditor(),
      onOpenPrivacy: () => this.openPrivacyPolicy(),
      onCopyDiagnostics: () => this.copyDiagnostics(),
      onEditDeviceName: () => this.openDeviceNameEditor(),
    })
  }

  private copyDiagnostics(): void {
    this.diagnosticService.copy({
      receiverReady: this.receiverReady, discoveryEnabled: this.discoveryEnabled,
      udpPort: this.discoveryPort, tcpPort: this.localTcpPort, nearbyCount: this.freshDevices.length,
      currentCount: this.currentTransfers.length, historyCount: this.historyTransfers.length, status: this.statusText,
    }, this.transferStore).then(() => {
      this.statusText = '诊断信息已复制'
      this.showToast('诊断信息已复制到剪贴板')
    }).catch((err: Error) => {
      this.statusText = `诊断信息复制失败：${errorText(err)}`
      this.showToast('诊断信息复制失败')
    })
  }

  private confirmClearHistory(): void {
    this.dialogService.confirm(
      this.getUIContext(),
      '清除临时传输空间？',
      '将清除未完成任务的临时分片，不会删除已完成文件和历史记录。',
      '确认清除',
    ).then((confirmed: boolean) => {
      if (confirmed) {
        this.clearTemporaryStorage().catch((err: Error) => {
          this.statusText = `临时空间清理失败：${errorText(err)}`
        })
      }
    })
  }

  private async clearTemporaryStorage(): Promise<void> {
    const stagingDir = `${this.abilityContext().filesDir}/HMTrans/Staging`
    this.statusText = '正在停止未完成任务'
    this.outgoingCoordinator.cancelAll()
    this.currentTransfers.forEach((item: TransferListItem) => this.transferService.cancelTransfer(item.id))
    const idleResults = await Promise.all([
      this.transferService.waitForIdle(),
      this.outgoingCoordinator.waitForIdle(),
    ])
    const networkIdle = idleResults[0]
    const queueIdle = idleResults[1]
    if (!networkIdle || !queueIdle) {
      throw new Error('仍有传输正在释放资源，请稍后重试')
    }
    this.currentTransfers = []
    this.activeTransferDeviceIds.clear()
    this.stagingStorageService.clear(stagingDir)
    this.persistTransferState(true)
    this.statusText = '临时传输空间和未完成任务已清除'
    this.showToast('临时传输空间已清除')
  }

  /** 对已拒绝的授权再次发起申请，并在不残留测试文件的前提下验证可写性。 */
  private async checkReceiveDirectory(): Promise<void> {
    try {
      if (this.receiveDirectory.length === 0) {
        await this.prepareReceiveDirectory(this.abilityContext())
        if (this.receiveDirectory.length === 0) {
          this.showToast('下载目录未授权，接收服务无法启动')
          return
        }
      }
      this.receiveDirectoryService.verify(this.receiveDirectory)
      const message = '下载目录可用：Download/HMTrans'
      this.statusText = message
      this.showToast(message)
    } catch (err) {
      this.transferStore.recordDiagnostic('STO-DIR-001', errorText(err)).catch(() => {})
      this.statusText = `下载目录不可写：${errorText(err)}`
      this.showToast('下载目录不可写，请在系统设置中允许访问下载目录')
    }
  }

  showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message, duration: 3000 })
    } catch (_err) {
      // 异步权限检查结束时页面可能已开始退出。
    }
  }

  confirmCancellation(title: string, message: string): Promise<number> {
    return this.dialogService.cancellationPolicy(this.getUIContext(), title, message)
  }

  confirmReceive(sender: string, fileName: string, sizeText: string): Promise<boolean> {
    return this.dialogService.confirmReceive(this.getUIContext(), sender, fileName, sizeText)
  }

  private confirmDeleteHistoryItem(item: TransferListItem): void {
    this.confirmHistoryMutation('删除这条传输记录？', item.fileName, () => {
      this.historyTransfers = this.historyTransfers.filter((row: TransferListItem) => row.id !== item.id)
      this.persistTransferState(true)
    })
  }

  private retryHistoryItem(item: TransferListItem): void {
    const matches = item.deviceId.length > 0 ?
      this.freshDevices.filter((device: DeviceInfo) => device.deviceId === item.deviceId) :
      this.freshDevices.filter((device: DeviceInfo) => device.deviceName === item.peerName)
    if (item.direction !== '发送' || matches.length !== 1) {
      this.statusText = `请先重新连接 ${item.peerName}`
      return
    }
    if (!this.archiveService.sourceExists(item.stagingPath)) {
      this.statusText = '源文件副本已不存在，请重新选择文件发送'
      return
    }
    this.historyTransfers = this.historyTransfers.filter((row: TransferListItem) => row.id !== item.id)
    const resumed = item.copyWith(item.progress, '用户重试，正在协商断点', TransferState.Waiting, nowText())
    this.currentTransfers = [resumed].concat(this.currentTransfers.filter((row: TransferListItem) => row.id !== item.id))
    this.persistTransferState(true); this.resumeWaitingTransfers(matches[0])
  }

  private confirmClearHistoryPeer(deviceKey: string, peerName: string): void {
    this.confirmHistoryMutation('清空此设备的历史？', peerName, () => {
      this.historyTransfers = this.historyTransfers.filter((row: TransferListItem) =>
        (row.deviceId.length > 0 ? row.deviceId : `name:${row.peerName}`) !== deviceKey)
      this.persistTransferState(true)
    })
  }

  private confirmClearAllHistory(): void {
    this.confirmHistoryMutation('清空全部历史？', '已完成文件不会被删除。', () => {
      this.historyTransfers = []
      this.persistTransferState(true)
    })
  }

  private confirmHistoryMutation(title: string, message: string, action: () => void): void {
    this.dialogService.confirm(this.getUIContext(), title, message).then((confirmed: boolean) => {
      if (confirmed) action()
    })
  }

  private confirmForgetDevice(device: DeviceInfo): void {
    this.dialogService.confirm(
      this.getUIContext(),
      `移除 ${device.deviceName}？`,
      '将删除本机保存的配对关系；下次连接需要重新输入六位配对码。传输历史不会被删除。',
      '移除设备',
    ).then((confirmed: boolean) => {
      if (!confirmed) return
      this.network().forgetDevice(device).catch((err: Error) => {
        this.statusText = `移除设备失败：${errorText(err)}`
      })
    })
  }

  @Computed
  get connectedDevices(): Array<DeviceInfo> {
    if (!this.discoveryEnabled) {
      return []
    }
    return this.freshDevices.filter((device: DeviceInfo) =>
      this.identityMatches(device.deviceId, device.identityFingerprint) && this.network().isBidirectionallyAlive(device.deviceId))
  }

  @Computed
  private get unpairedDevices(): Array<DeviceInfo> {
    return this.freshDevices.filter((device: DeviceInfo) => !this.isTrusted(device.deviceId))
  }

  @Computed
  private get offlineDeviceIds(): Array<string> {
    const onlineIds = this.discoveryEnabled ? this.connectedDevices.map((device: DeviceInfo) => device.deviceId) : []
    return this.trustedDeviceIds.filter((deviceId: string) => onlineIds.indexOf(deviceId) < 0)
  }

  @Computed
  private get offlineDevices(): Array<DeviceInfo> {
    const devices: Array<DeviceInfo> = []
    this.offlineDeviceIds.forEach((deviceId: string) => {
      const device = this.persistedDevice(deviceId)
      if (device) {
        devices.push(device)
      }
    })
    return devices
  }

  private persistedDevice(deviceId: string): DeviceInfo | undefined {
    const matches = this.persistedDevices.filter((device: DeviceInfo) => device.deviceId === deviceId)
    return matches.length > 0 ? matches[0] : undefined
  }

  private async bootstrap(): Promise<void> {
    const context = this.abilityContext()
    this.notificationActionService.register(context)
    const accepted = await this.ensurePrivacyConsent(context)
    if (!accepted) {
      this.statusText = '未同意隐私政策，服务未启动'
      return
    }
    await this.loadPreferences(context)
    this.localDeviceDisplayName = await this.deviceIdentityService.loadUserVisibleDeviceName(context)
    await this.restoreTransferState(context)
    // 七天过期清理会跳过所有从本地状态恢复、仍可续传的任务。
    this.stagingStorageService.pruneExpired(
      `${context.filesDir}/HMTrans/Staging`,
      this.currentTransfers.flatMap((item: TransferListItem) => [item.id, item.groupId]),
      7 * 24 * 60 * 60 * 1000
    )
    await this.network().refreshNetworkName()
    this.regeneratePairingCode()
    await this.prepareReceiveDirectory(context)
    await this.network().ensureReceiverAndDiscovery()
    this.network().startDevicePruning()
    this.networkChangeService.start(() => this.network().handleNetworkChanged())
  }

  // MARK: 隐私、存储与持久化偏好

  private async ensurePrivacyConsent(context: common.UIAbilityContext): Promise<boolean> {
    try {
      const store = await preferences.getPreferences(context, PREFERENCES_NAME)
      const acceptedVersion = await store.get(PRIVACY_ACCEPTED_VERSION_KEY, '') as string
      if (acceptedVersion === PRIVACY_VERSION) {
        this.privacyAccepted = true
        this.contentUnlocked = true
        return true
      }
      const agreed = await this.showPrivacyPrompt()
      if (!agreed) {
        this.privacyAccepted = false
        return false
      }
      await store.put(PRIVACY_ACCEPTED_KEY, true)
      await store.put(PRIVACY_ACCEPTED_VERSION_KEY, PRIVACY_VERSION)
      await store.flush()
      this.privacyAccepted = true
      this.contentUnlocked = true
      return true
    } catch (err) {
      this.statusText = `隐私政策确认失败：${errorText(err)}`
      this.privacyAccepted = false
      this.contentUnlocked = false
      return false
    }
  }

  private showPrivacyPrompt(): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      this.runOnUi(() => {
        this.privacyConsentResolver = resolve
        this.showPrivacyConsentDialog = true
      })
    })
  }

  private resolvePrivacyConsent(agreed: boolean): void {
    this.showPrivacyConsentDialog = false
    const resolver = this.privacyConsentResolver
    this.privacyConsentResolver = undefined
    if (resolver) {
      resolver(agreed)
    }
    if (!agreed) {
      this.exitForPrivacyDecline()
    }
  }

  private openPrivacyPolicy(): void {
    const context = this.abilityContext()
    context.startAbility({
      action: 'ohos.want.action.viewData',
      uri: PRIVACY_POLICY_URL,
    }).catch((_err: Error) => {
      this.statusText = `请手动访问隐私政策：${PRIVACY_POLICY_URL}`
    })
  }

  private exitForPrivacyDecline(): void {
    this.privacyAccepted = false
    this.contentUnlocked = false
    const context = this.abilityContext()
    context.terminateSelf().catch((_err: Error) => {
      this.statusText = '未同意隐私政策，服务未启动'
    })
  }

  private async prepareReceiveDirectory(context: common.UIAbilityContext): Promise<void> {
    try {
      this.receiveDirectory = await this.receiveDirectoryService.prepare(context)
      this.statusText = `接收目录：${this.receiveDirectory}`
      if (this.receiverEnabled && !this.receiverReady) {
        await this.network().startReceiver(context)
      }
    } catch (err) {
      this.receiveDirectory = ''
      this.statusText = `下载目录初始化失败：${errorText(err)}`
    }
  }

  private async loadPreferences(context: common.UIAbilityContext): Promise<void> {
    try {
      const saved = await this.padPreferencesService.load(context)
      this.targetIp = saved.host; this.portText = saved.remotePort
      this.localTcpPortText = saved.localTcpPort; this.discoveryPortText = saved.discoveryPort
      this.deviceId = saved.deviceId; this.identityFingerprint = saved.identityFingerprint
      this.trustedDeviceIds = saved.trustedDeviceIds; this.trustedFingerprints = saved.trustedFingerprints
      this.backgroundProtectionEnabled = saved.backgroundProtectionEnabled
      this.autoReceiveTrustedEnabled = saved.autoReceiveTrustedEnabled
      this.receiverEnabled = saved.receiverEnabled; this.discoveryEnabled = saved.discoveryEnabled
      this.customDeviceDisplayName = saved.customDeviceName.trim()
      await this.backgroundTransferService.setEnabled(saved.backgroundProtectionEnabled, context)
    } catch (err) {
      this.deviceId = `pad-${Date.now()}-${Math.floor(Math.random() * 100000)}`
      this.identityFingerprint = `${Date.now()}${Math.floor(Math.random() * 1000000000)}`
      this.statusText = `偏好读取失败：${errorText(err)}`
    }
  }

  private async restoreTransferState(context: common.UIAbilityContext): Promise<void> {
    try {
      await this.transferStore.initialize(context)
      this.persistedDevices = await this.transferStore.loadDevices()
      const snapshot: TransferSnapshot = await this.transferStore.loadSnapshot()
      const restoredCurrent: Array<TransferListItem> = []
      const unavailableHistory: Array<TransferListItem> = []
      snapshot.current.forEach((item: TransferListItem) => {
        if (item.direction === '发送' && !this.archiveService.sourceExists(item.stagingPath)) {
          unavailableHistory.push(this.sourceUnavailableItem(item))
          return
        }
        if (item.state === TransferState.Active || item.state === TransferState.Preparing ||
          item.state === TransferState.Verifying) {
          restoredCurrent.push(item.copyWith(item.progress, '应用重新打开，等待设备连接后继续',
            TransferState.Waiting, nowText()))
          return
        }
        restoredCurrent.push(item)
      })
      this.currentTransfers = restoredCurrent
      this.historyTransfers = unavailableHistory.concat(snapshot.history)
      this.persistTransferState(true)
    } catch (err) {
      this.statusText = `传输记录恢复失败：${errorText(err)}`
    }
  }

  /** 迁移仅依赖旧 Picker 的任务，避免对已过期 URI 无限重试。 */
  private sourceUnavailableItem(item: TransferListItem): TransferListItem {
    return new TransferListItem({
      id: item.id, groupId: item.groupId, fileName: item.fileName, peerName: item.peerName,
      direction: item.direction, progress: item.progress,
      detail: '源文件授权已失效，请重新选择文件发送', state: TransferState.Failed, timeText: nowText(),
      startedAt: item.startedAt, fileSize: item.fileSize, fileType: item.fileType,
      localPath: item.localPath, stagingPath: item.stagingPath, deviceId: item.deviceId,
      errorCode: 'SRC-MISSING-001', confirmedOffset: item.confirmedOffset,
      sourceSize: item.sourceSize, sourceFileCount: item.sourceFileCount,
    })
  }

  persistTransferState(immediate: boolean = false): void {
    if (immediate) {
      if (this.persistenceTimer !== undefined) {
        clearTimeout(this.persistenceTimer)
        this.persistenceTimer = undefined
      }
      this.transferStore.saveSnapshot(this.currentTransfers, this.historyTransfers).catch((err: Error) => {
        this.runOnUi(() => { this.statusText = `传输状态保存失败：${errorText(err)}` })
      })
      return
    }
    if (this.persistenceTimer !== undefined) {
      return
    }
    this.persistenceTimer = setTimeout(() => {
      this.persistenceTimer = undefined
      this.transferStore.saveSnapshot(this.currentTransfers, this.historyTransfers).catch((err: Error) => {
        this.runOnUi(() => { this.statusText = `传输状态保存失败：${errorText(err)}` })
      })
    }, 750)
  }

  private regeneratePairingCode(): void {
    const raw = `${100000 + Math.floor(Math.random() * 900000)}`
    this.pairingCode = `${raw.substring(0, 3)} ${raw.substring(3, 6)}`
    this.pairingSeconds = 180
    if (this.pairingTimer !== undefined) {
      clearInterval(this.pairingTimer)
    }
    this.pairingTimer = setInterval(() => {
      this.pairingSeconds -= 1
      if (this.pairingSeconds <= 0) {
        this.regeneratePairingCode()
      }
    }, 1000)
  }

  private async applyNetworkPorts(): Promise<void> {
    const tcp = Number(this.localTcpPortText)
    const udp = Number(this.discoveryPortText)
    if (!Number.isInteger(tcp) || tcp <= 0 || tcp > 65535 || !Number.isInteger(udp) || udp <= 0 || udp > 65535) {
      this.statusText = '端口必须是 1 到 65535 之间的整数'
      return
    }
    this.localTcpPortText = `${tcp}`
    this.discoveryPortText = `${udp}`
    try {
      await this.padPreferencesService.savePorts(this.abilityContext(), this.localTcpPortText, this.discoveryPortText)
      this.receiverReady = false
      await this.transferService.stopReceive()
      await this.network().stopDiscovery()
      await this.network().ensureReceiverAndDiscovery()
      this.statusText = `已应用 UDP ${udp} · TCP ${tcp}`
      this.showToast('网络端口已保存，服务已重新启动')
    } catch (err) {
      this.statusText = `端口保存失败：${errorText(err)}`
      this.showToast('端口保存失败，请检查端口是否被占用')
    }
  }

  private openPortEditor(): void {
    this.draftUdpPort = this.discoveryPortText
    this.draftTcpPort = this.localTcpPortText
    this.showPortEditor = true
  }

  async saveTarget(): Promise<void> {
    try {
      await this.padPreferencesService.saveTarget(this.abilityContext(), this.targetIp, this.portText)
    } catch (err) {
      this.statusText = `目标保存失败：${errorText(err)}`
    }
  }

  async trustDevice(deviceId?: string, fingerprint?: string): Promise<void> {
    if (!deviceId || deviceId.length === 0 || !fingerprint || fingerprint.length === 0) {
      return
    }
    if (this.trustedDeviceIds.indexOf(deviceId) < 0) {
      this.trustedDeviceIds = this.trustedDeviceIds.concat([deviceId])
    }
    this.trustedFingerprints.set(deviceId, fingerprint)
    try {
      await this.padPreferencesService.saveTrust(this.abilityContext(), this.trustedDeviceIds,
        this.trustedFingerprints)
    } catch (err) {
      this.statusText = `配对信任保存失败：${errorText(err)}`
      throw new Error(errorText(err))
    }
  }

  /** 只清理本机信任与在线确认；远端通知由网络控制器负责，避免相互回送解除配对。 */
  async forgetTrustedDevice(deviceId: string, statusMessage: string): Promise<void> {
    this.trustedDeviceIds = this.trustedDeviceIds.filter((id: string) => id !== deviceId)
    this.trustedFingerprints.delete(deviceId)
    this.persistedDevices = this.persistedDevices.filter((row: DeviceInfo) => row.deviceId !== deviceId)
    this.selectedDeviceIds = this.selectedDeviceIds.filter((id: string) => id !== deviceId)
    this.confirmedDeviceLastSeenAt.delete(deviceId)
    if (this.selectedDeviceId === deviceId) this.selectedDeviceId = ''
    const device = this.nearbyDevices.find((row: DeviceInfo) => row.deviceId === deviceId)
    if (device && this.targetIp === device.ip) {
      this.targetIp = ''
      this.portText = '51888'
      await this.saveTarget()
    }
    await this.padPreferencesService.saveTrust(this.abilityContext(), this.trustedDeviceIds,
      this.trustedFingerprints)
    await this.transferStore.removeDevice(deviceId)
    this.statusText = statusMessage
  }

  async rememberDevice(device: DeviceInfo): Promise<void> {
    this.persistedDevices = this.persistedDevices
      .filter((item: DeviceInfo) => item.deviceId !== device.deviceId)
      .concat([device])
    await this.transferStore.upsertDevice(device)
  }

  isTrusted(deviceId?: string): boolean {
    if (!deviceId || deviceId.length === 0) {
      return false
    }
    return this.trustedDeviceIds.indexOf(deviceId) >= 0
  }

  identityMatches(deviceId?: string, fingerprint?: string): boolean {
    if (!deviceId || !fingerprint || fingerprint.length === 0 || !this.isTrusted(deviceId)) {
      return false
    }
    return this.trustedFingerprints.get(deviceId) === fingerprint
  }

  runOnUi(task: () => void): void {
    if (!this.pageActive) return
    try {
      this.getUIContext().runScopedTask(task)
    } catch (_) {
      // 作用域任务失败通常意味着页面或其 UI 上下文已经销毁。
      // 此时直接执行回调会从任意工作线程修改已经失效的响应式状态。
    }
  }

  updateBackgroundTransferActivity(active: boolean): void {
    const context = this.abilityContext()
    if (active) {
      this.backgroundTransferService.begin(context).catch((err: Error) => {
        this.runOnUi(() => {
          this.statusText = `后台传输保护启动失败：${errorText(err)}`
        })
      })
    } else {
      this.backgroundTransferService.end(context).catch(() => {})
    }
  }

  abilityContext(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext
  }

  async startReceiverForSettings(): Promise<boolean> {
    const context = this.abilityContext()
    if (this.receiveDirectory.length > 0) {
      await this.network().startReceiver(context)
    } else {
      await this.prepareReceiveDirectory(context)
    }
    return this.receiverReady
  }

  stopReceiverForSettings(): Promise<void> {
    return this.transferService.stopReceive()
  }

  restartDiscoveryForSettings(): Promise<void> {
    return this.network().restartDiscovery()
  }

  stopDiscoveryForSettings(): Promise<void> {
    return this.network().stopDiscovery()
  }

  private network(): PadNetworkController {
    if (!this.networkController) this.networkController = new PadNetworkController(this)
    return this.networkController
  }

  resumeWaitingTransfers(device: DeviceInfo): void {
    this.network().resumeWaitingTransfers(device)
  }

  @Computed
  get selectedDevice(): DeviceInfo | undefined {
    const matched = this.connectedDevices.filter((device: DeviceInfo) => device.deviceId === this.selectedDeviceId)
    return matched.length > 0 ? matched[0] : undefined
  }

  @Computed
  get freshDevices(): Array<DeviceInfo> {
    const now = Date.now()
    return this.nearbyDevices.filter((device: DeviceInfo) => {
      return now - (this.deviceLastSeenAt.get(device.deviceId) ?? 0) < DEVICE_TTL_MS
    })
  }

  @Computed
  get localTcpPort(): number {
    const value = Number(this.localTcpPortText)
    return Number.isInteger(value) && value > 0 && value <= 65535 ? value : DEFAULT_PORT
  }

  @Computed
  get discoveryPort(): number {
    const value = Number(this.discoveryPortText)
    return Number.isInteger(value) && value > 0 && value <= 65535 ? value : DISCOVERY_PORT
  }

  localDeviceName(): string {
    const preferred = this.customDeviceDisplayName.length > 0 ?
      this.customDeviceDisplayName : this.localDeviceDisplayName
    return this.deviceIdentityService.deviceName(preferred)
  }

  private openDeviceNameEditor(): void {
    this.draftDeviceName = this.localDeviceName()
    this.showDeviceNameEditor = true
  }

  private async saveDeviceName(): Promise<void> {
    const value = this.draftDeviceName.trim()
    if (value.length === 0) {
      this.showToast('本机显示名称不能为空')
      return
    }
    const previous = this.customDeviceDisplayName
    this.customDeviceDisplayName = value
    this.showDeviceNameEditor = false
    try {
      await this.padPreferencesService.saveString(this.abilityContext(), 'customDeviceName', value)
      await this.network().restartDiscovery()
      this.statusText = `本机显示名称已更新为 ${value}`
      this.showToast('名称已更新，Mac 端会自动刷新')
    } catch (err) {
      this.customDeviceDisplayName = previous
      this.statusText = `本机显示名称保存失败：${errorText(err)}`
      this.showToast('名称保存失败')
    }
  }

  /** 对外广播用户可见的 HarmonyOS 版本，而不是 OpenHarmony 构建字符串。 */
  localSystemVersion(): string {
    return this.deviceIdentityService.systemVersion()
  }

  private transfers(): PadTransferController {
    if (!this.transferController) {
      this.transferController = new PadTransferController(
        this, this.transferService, this.transferStore, this.archiveService, this.stagingStorageService,
        this.dropUriService, this.transferStateService, this.outgoingCoordinator,
      )
    }
    return this.transferController
  }

  private selectAndSendFile(): void {
    this.transfers().selectAndSendFile()
  }

  private sendUris(uris: Array<string>): Promise<void> {
    return this.transfers().sendUris(uris)
  }

  private transferTargetLabel(): string {
    return this.transfers().transferTargetLabel()
  }

  sendPreparedSource(source: SendableSource, device: DeviceInfo, reuseTransferId?: string,
    groupId?: string, cleanupSource: boolean = true): Promise<boolean> {
    return this.transfers().sendPreparedSource(source, device, reuseTransferId, groupId, cleanupSource)
  }

  private handleDrop(event: DragEvent): void {
    this.transfers().handleDrop(event)
  }

  upsertCurrentTransfer(item: TransferListItemOptions): void {
    this.transfers().upsertCurrentTransfer(item)
  }

  updateCurrentTransfer(id: string, progress: number, detail: string): void {
    this.transfers().updateCurrentTransfer(id, progress, detail)
  }

  toggleTransferPause(item: TransferListItem): void {
    this.transfers().toggleTransferPause(item)
  }

  private toggleTransferGroup(item: TransferListItem): void {
    this.transfers().toggleTransferGroup(item)
  }

  private confirmCancelTransfer(item: TransferListItem): void {
    this.transfers().confirmCancelTransfer(item)
  }

  cancelTransfer(item: TransferListItem): void {
    this.transfers().cancelTransfer(item)
  }

  private confirmCancelTransferGroup(item: TransferListItem): void {
    this.transfers().confirmCancelTransferGroup(item)
  }

  markCurrentTransferState(id: string, state: string, detail: string): void {
    this.transfers().markCurrentTransferState(id, state, detail)
  }

  completeTransfer(id: string, success: boolean, detail: string, localPath?: string): void {
    this.transfers().completeTransfer(id, success, detail, localPath)
  }

  historyDeviceIdForIncoming(meta: FileMeta): string {
    return this.transfers().historyDeviceIdForIncoming(meta)
  }

  markReceivedFilePublished(transferId: string, fileName: string, path: string): Promise<void> {
    return this.transfers().markReceivedFilePublished(transferId, fileName, path)
  }

  updateHistoryDetail(id: string, detailPrefix: string): void {
    this.transfers().updateHistoryDetail(id, detailPrefix)
  }

  progressDetail(id: string, current: number, total: number): string {
    return this.transfers().progressDetail(id, current, total)
  }
}
