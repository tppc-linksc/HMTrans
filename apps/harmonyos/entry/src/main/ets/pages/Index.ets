import { common } from '@kit.AbilityKit'
import { preferences } from '@kit.ArkData'
import { deviceInfo, settings } from '@kit.BasicServicesKit'
import { picker } from '@kit.CoreFileKit'
import { wifiManager } from '@kit.ConnectivityKit'
import { DEFAULT_PORT, DISCOVERY_PORT, DeviceInfo, FileMeta, PairingRequest, createPairingRequest } from '../common/Protocol'
import { fileTypeLabel, formatBytes, nowText } from '../common/Formatters'
import { TransferListItem, TransferListItemOptions } from '../models/TransferListItem'
import { PadConnectionPage } from '../components/ConnectionPage'
import { TransferHistoryPage } from '../components/TransferHistoryPage'
import { PadSettingsPage } from '../components/SettingsPage'
import { BottomDock } from '../components/BottomDock'
import { PairingOverlay, PortEditorOverlay, PrivacyConsentOverlay } from '../components/AppOverlays'
import { ArchiveService, SendableSource } from '../services/ArchiveService'
import { BackgroundTransferService } from '../services/BackgroundTransferService'
import { StagingStorageService } from '../services/StagingStorageService'
import { DiscoveryService } from '../services/DiscoveryService'
import { TcpTransferService } from '../services/TcpTransferService'
import { DropUriService } from '../services/DropUriService'
import { ReceiveDirectoryService } from '../services/ReceiveDirectoryService'
import { PadPreferencesService } from '../services/PadPreferencesService'
import { TransferStateService } from '../services/TransferStateService'
import { OutgoingTransferCallbacks, OutgoingTransferCoordinator } from '../services/OutgoingTransferCoordinator'
import { DiagnosticService } from '../services/DiagnosticService'
import { TransferSnapshot, TransferStore } from '../persistence/TransferStore'

const DEVICE_TTL_MS: number = 12000
const DEVICE_PRUNE_INTERVAL_MS: number = 4000
const PREFERENCES_NAME: string = 'HMTrans'
const PRIVACY_ACCEPTED_KEY: string = 'privacyAccepted'
const PRIVACY_ACCEPTED_VERSION_KEY: string = 'privacyAcceptedVersion'
const PRIVACY_VERSION: string = '2026-07-12'
const PRIVACY_POLICY_URL: string = 'https://hmt.tppc.top/privacy.html'

@Entry
@ComponentV2
struct Index {
  // Reactive view state stays here; file/network/storage work lives in services below.
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
  @Local localDeviceDisplayName: string = ''
  @Local receiverEnabled: boolean = true
  @Local discoveryEnabled: boolean = true
  @Local backgroundProtectionEnabled: boolean = true
  @Local autoReceiveTrustedEnabled: boolean = true
  @Local pairingCode: string = '000 000'
  @Local pairingSeconds: number = 180
  @Local pairingTarget: DeviceInfo | undefined = undefined
  @Local pairingInput: string = ''
  @Local showPortEditor: boolean = false
  @Local draftUdpPort: string = `${DISCOVERY_PORT}`
  @Local draftTcpPort: string = `${DEFAULT_PORT}`
  @Local compactLayout: boolean = false
  @Local showPrivacyConsentDialog: boolean = false
  @Local contentUnlocked: boolean = false
  private transferService: TcpTransferService = new TcpTransferService()
  private transferStore: TransferStore = new TransferStore()
  private archiveService: ArchiveService = new ArchiveService()
  private backgroundTransferService: BackgroundTransferService = new BackgroundTransferService()
  private stagingStorageService: StagingStorageService = new StagingStorageService()
  private dropUriService: DropUriService = new DropUriService()
  private receiveDirectoryService: ReceiveDirectoryService = new ReceiveDirectoryService()
  private padPreferencesService: PadPreferencesService = new PadPreferencesService()
  private transferStateService: TransferStateService = new TransferStateService()
  private outgoingCoordinator: OutgoingTransferCoordinator =
    new OutgoingTransferCoordinator(this.transferService, this.archiveService)
  private diagnosticService: DiagnosticService = new DiagnosticService()
  private discoveryService?: DiscoveryService
  private bootstrapped: boolean = false
  private notificationActionsRegistered: boolean = false
  private privacyAccepted: boolean = false
  private privacyConsentResolver?: (agreed: boolean) => void
  private deviceId: string = ''
  private identityFingerprint: string = ''
  private trustedFingerprints: Map<string, string> = new Map()
  private deviceLastSeenAt: Map<string, number> = new Map()
  private confirmedDeviceLastSeenAt: Map<string, number> = new Map()
  private activeTransferDeviceIds: Map<string, string> = new Map()
  private receiveDirectory: string = ''
  private receiverReady: boolean = false
  private pruneTimer?: number
  private pairingTimer?: number
  private persistenceTimer?: number

  aboutToAppear(): void {
    if (this.bootstrapped) {
      return
    }
    this.bootstrapped = true
    this.bootstrap()
  }

  onPageShow(): void {
    if (!this.bootstrapped || !this.privacyAccepted) {
      return
    }
    this.startDevicePruning()
    this.statusText = this.selectedDevice ? this.statusText : '正在重新发现设备'
    this.refreshNetworkName()
    this.ensureReceiverAndDiscovery().catch((err: Error) => {
      this.statusText = `服务恢复失败：${JSON.stringify(err)}`
    })
  }

  build() {
    Stack() {
      if (this.contentUnlocked) {
        this.MainLayout()
      } else {
        this.PrivacyBlankPage()
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
  private PrivacyBlankPage() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor('#FFFFFF')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
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
          onSubmit: () => this.submitPairing(),
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
      if (this.activePage === 'connection') {
        this.ConnectionPage()
      } else if (this.activePage === 'history') {
        this.TransferPage()
      } else {
        this.SettingsPage()
      }
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
      targetIp: this.targetIp,
      udpPort: this.discoveryPort,
      tcpPort: this.localTcpPort,
      pairingCode: this.pairingCode,
      pairingSeconds: this.pairingSeconds,
      connectedDevices: this.connectedDevices,
      offlineDevices: this.offlineDevices,
      unpairedDevices: this.unpairedDevices,
      selectedDeviceIds: this.selectedDeviceIds,
      onRegenerateCode: () => this.regeneratePairingCode(),
      onPairDevice: (device: DeviceInfo) => this.beginPairing(device),
      onReconnectDevice: (device: DeviceInfo) => this.reconnectTrustedDevice(device),
      onToggleTarget: (device: DeviceInfo) => this.toggleTransferTarget(device),
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
      onFilterChanged: (value: string) => { this.historyFilter = value },
      onTogglePause: (item: TransferListItem) => this.toggleTransferPause(item),
      onCancel: (item: TransferListItem) => this.confirmCancelTransfer(item),
      onToggleGroup: (item: TransferListItem) => this.toggleTransferGroup(item),
      onCancelGroup: (item: TransferListItem) => this.confirmCancelTransferGroup(item),
      onDeleteHistory: (item: TransferListItem) => this.confirmDeleteHistoryItem(item),
      onRetryHistory: (item: TransferListItem) => this.retryHistoryItem(item),
      onClearPeer: (peerName: string) => this.confirmClearHistoryPeer(peerName),
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
      onReceiverChanged: (enabled: boolean) => this.setReceiverEnabled(enabled),
      onDiscoveryChanged: (enabled: boolean) => this.setDiscoveryEnabled(enabled),
      onBackgroundChanged: (enabled: boolean) => this.setBackgroundProtectionEnabled(enabled),
      onAutoReceiveChanged: (enabled: boolean) => this.setAutoReceiveTrustedEnabled(enabled),
      onCheckDownload: () => { this.checkReceiveDirectory() },
      onClearStaging: () => this.confirmClearHistory(),
      onEditPorts: () => this.openPortEditor(),
      onOpenPrivacy: () => this.openPrivacyPolicy(),
      onCopyDiagnostics: () => this.copyDiagnostics(),
    })
  }

  private copyDiagnostics(): void {
    this.diagnosticService.copy({
      receiverReady: this.receiverReady, discoveryEnabled: this.discoveryEnabled,
      udpPort: this.discoveryPort, tcpPort: this.localTcpPort, nearbyCount: this.freshDevices.length,
      currentCount: this.currentTransfers.length, historyCount: this.historyTransfers.length, status: this.statusText,
    }, this.transferStore).then(() => { this.statusText = '诊断信息已复制' }).catch((err: Error) => {
      this.statusText = `诊断信息复制失败：${JSON.stringify(err)}`
    })
  }

  private confirmClearHistory(): void {
    this.getUIContext().getPromptAction().showDialog({
      title: '清除临时传输空间？',
      message: '将清除未完成任务的临时分片，不会删除已完成文件和历史记录。',
      buttons: [
        { text: '取消', color: '#64748B' },
        { text: '确认清除', color: '#C2413A' },
      ],
    }).then((result) => {
      if (result.index === 1) {
        this.clearTemporaryStorage()
      }
    }).catch((_err: Error) => {})
  }

  private clearTemporaryStorage(): void {
    const stagingDir = `${this.abilityContext().filesDir}/HMTrans/Staging`
    this.currentTransfers.forEach((item: TransferListItem) => this.transferService.cancelTransfer(item.id))
    this.currentTransfers = []
    this.activeTransferDeviceIds.clear()
    this.stagingStorageService.clear(stagingDir)
    this.persistTransferState(true)
    this.statusText = '临时传输空间和未完成任务已清除'
  }

  /** Re-requests a denied grant, then verifies writability without leaving a test file. */
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
      this.transferStore.recordDiagnostic('STO-DIR-001', JSON.stringify(err)).catch(() => {})
      this.statusText = `下载目录不可写：${JSON.stringify(err)}`
      this.showToast('下载目录不可写，请在系统设置中允许访问下载目录')
    }
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message, duration: 3000 })
    } catch (_err) {
      // The page may already be leaving when an asynchronous permission check finishes.
    }
  }

  private confirmDeleteHistoryItem(item: TransferListItem): void {
    this.confirmHistoryMutation('删除这条传输记录？', item.fileName, () => {
      this.historyTransfers = this.historyTransfers.filter((row: TransferListItem) => row.id !== item.id)
      this.persistTransferState(true)
    })
  }

  private retryHistoryItem(item: TransferListItem): void {
    const matches = this.freshDevices.filter((device: DeviceInfo) =>
      device.deviceId === item.deviceId || device.deviceName === item.peerName)
    if (item.direction !== '发送' || matches.length === 0) {
      this.statusText = `请先重新连接 ${item.peerName}`
      return
    }
    if (!this.archiveService.sourceExists(item.stagingPath)) {
      this.statusText = '源文件副本已不存在，请重新选择文件发送'
      return
    }
    this.historyTransfers = this.historyTransfers.filter((row: TransferListItem) => row.id !== item.id)
    const resumed = item.copyWith(item.progress, '用户重试，正在协商断点', '等待重连', nowText())
    this.currentTransfers = [resumed].concat(this.currentTransfers.filter((row: TransferListItem) => row.id !== item.id))
    this.persistTransferState(true); this.resumeWaitingTransfers(matches[0])
  }

  private confirmClearHistoryPeer(peerName: string): void {
    this.confirmHistoryMutation('清空此设备的历史？', peerName, () => {
      this.historyTransfers = this.historyTransfers.filter((row: TransferListItem) => row.peerName !== peerName)
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
    this.getUIContext().getPromptAction().showDialog({
      title,
      message,
      buttons: [
        { text: '取消', color: '#64748B' },
        { text: '确认', color: '#C2413A' },
      ],
    }).then((result) => {
      if (result.index === 1) action()
    }).catch(() => {})
  }

  @Computed
  private get connectedDevices(): Array<DeviceInfo> {
    if (!this.discoveryEnabled) {
      return []
    }
    return this.freshDevices.filter((device: DeviceInfo) =>
      this.identityMatches(device.deviceId, device.identityFingerprint) && this.isBidirectionallyAlive(device.deviceId))
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
    this.registerNotificationActions(context)
    const accepted = await this.ensurePrivacyConsent(context)
    if (!accepted) {
      this.statusText = '未同意隐私政策，服务未启动'
      return
    }
    await this.loadPreferences(context)
    await this.restoreTransferState(context)
    // Seven-day cleanup excludes every resumable task restored from local state.
    this.stagingStorageService.pruneExpired(
      `${context.filesDir}/HMTrans/Staging`,
      this.currentTransfers.flatMap((item: TransferListItem) => [item.id, item.groupId]),
      7 * 24 * 60 * 60 * 1000
    )
    await this.refreshNetworkName()
    this.regeneratePairingCode()
    await this.prepareReceiveDirectory(context)
    await this.ensureReceiverAndDiscovery()
    this.startDevicePruning()
  }

  // MARK: Privacy, storage and persisted preferences

  /** Keeps notification and in-app pause/cancel mutations on the same task model. */
  private registerNotificationActions(context: common.UIAbilityContext): void {
    if (this.notificationActionsRegistered) return
    this.notificationActionsRegistered = true
    context.eventHub.on('hmtransTransferAction', (action: string) => {
      this.runOnUi(() => {
        if (action === 'pause_all') {
          const active = this.currentTransfers.filter((row: TransferListItem) =>
            row.state === '传输中' || row.state === '准备中')
          const rows = active.length > 0 ? active : this.currentTransfers.filter((row: TransferListItem) =>
            row.state === '已暂停' || row.state === '等待重连')
          rows.forEach((row: TransferListItem) => this.toggleTransferPause(row))
          this.statusText = active.length > 0 ? '已从通知暂停全部活动任务' : '已从通知继续可恢复任务'
        } else if (action === 'cancel_all') {
          this.currentTransfers.slice().forEach((row: TransferListItem) => this.cancelTransfer(row))
          this.statusText = '已从通知取消全部任务，可恢复数据仍保留在私有目录'
        }
      })
    })
  }

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
      this.statusText = `隐私政策确认失败：${JSON.stringify(err)}`
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
        await this.startReceiver(context)
      }
    } catch (err) {
      this.receiveDirectory = ''
      this.statusText = `下载目录初始化失败：${JSON.stringify(err)}`
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
      this.backgroundTransferService.setEnabled(saved.backgroundProtectionEnabled, context)
    } catch (err) {
      this.deviceId = `pad-${Date.now()}-${Math.floor(Math.random() * 100000)}`
      this.identityFingerprint = `${Date.now()}${Math.floor(Math.random() * 1000000000)}`
      this.statusText = `偏好读取失败：${JSON.stringify(err)}`
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
        if (item.state === '传输中' || item.state === '准备中' || item.state === '校验中') {
          restoredCurrent.push(item.copyWith(item.progress, '应用重新打开，等待设备连接后继续', '等待重连', nowText()))
          return
        }
        restoredCurrent.push(item)
      })
      this.currentTransfers = restoredCurrent
      this.historyTransfers = unavailableHistory.concat(snapshot.history)
      this.persistTransferState(true)
    } catch (err) {
      this.statusText = `传输记录恢复失败：${JSON.stringify(err)}`
    }
  }

  /** Migrates legacy Picker-only tasks instead of retrying an expired URI forever. */
  private sourceUnavailableItem(item: TransferListItem): TransferListItem {
    return new TransferListItem({
      id: item.id, groupId: item.groupId, fileName: item.fileName, peerName: item.peerName,
      direction: item.direction, progress: item.progress,
      detail: '源文件授权已失效，请重新选择文件发送', state: '失败', timeText: nowText(),
      startedAt: item.startedAt, fileSize: item.fileSize, fileType: item.fileType,
      localPath: item.localPath, stagingPath: item.stagingPath, deviceId: item.deviceId,
      errorCode: 'SRC-MISSING-001', confirmedOffset: item.confirmedOffset,
      sourceSize: item.sourceSize, sourceFileCount: item.sourceFileCount,
    })
  }

  private persistTransferState(immediate: boolean = false): void {
    if (immediate) {
      if (this.persistenceTimer !== undefined) {
        clearTimeout(this.persistenceTimer)
        this.persistenceTimer = undefined
      }
      this.transferStore.saveSnapshot(this.currentTransfers, this.historyTransfers).catch((_err: Error) => {})
      return
    }
    if (this.persistenceTimer !== undefined) {
      return
    }
    this.persistenceTimer = setTimeout(() => {
      this.persistenceTimer = undefined
      this.transferStore.saveSnapshot(this.currentTransfers, this.historyTransfers).catch((_err: Error) => {})
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

  // MARK: Service switches and network lifecycle

  private setReceiverEnabled(enabled: boolean): void {
    this.receiverEnabled = enabled
    this.persistBooleanPreference('receiverEnabled', enabled)
    if (enabled) {
      const context = this.abilityContext()
      const start = this.receiveDirectory.length > 0 ? this.startReceiver(context) :
        this.prepareReceiveDirectory(context).then(() => this.receiverReady)
      start.catch((err: Error) => { this.statusText = `接收服务启动失败：${JSON.stringify(err)}` })
    } else {
      this.receiverReady = false
      this.transferService.stopReceive().catch(() => {})
      this.statusText = '接收服务已关闭，仍可发现和发送'
    }
  }

  private setDiscoveryEnabled(enabled: boolean): void {
    this.discoveryEnabled = enabled
    this.persistBooleanPreference('discoveryEnabled', enabled)
    if (enabled) {
      this.restartDiscovery().catch((err: Error) => {
        this.statusText = `发现服务启动失败：${JSON.stringify(err)}`
      })
    } else {
      this.stopDiscovery().catch(() => {})
      this.statusText = '自动发现已关闭，接收服务保持当前状态'
    }
  }

  private setBackgroundProtectionEnabled(enabled: boolean): void {
    this.backgroundProtectionEnabled = enabled
    this.backgroundTransferService.setEnabled(enabled, this.abilityContext())
    this.persistBooleanPreference('backgroundProtectionEnabled', enabled)
  }

  private setAutoReceiveTrustedEnabled(enabled: boolean): void {
    this.autoReceiveTrustedEnabled = enabled
    this.persistBooleanPreference('autoReceiveTrustedEnabled', enabled)
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
      await this.stopDiscovery()
      await this.ensureReceiverAndDiscovery()
      this.statusText = `已应用 UDP ${udp} · TCP ${tcp}`
    } catch (err) {
      this.statusText = `端口保存失败：${JSON.stringify(err)}`
    }
  }

  private openPortEditor(): void {
    this.draftUdpPort = this.discoveryPortText
    this.draftTcpPort = this.localTcpPortText
    this.showPortEditor = true
  }

  private async saveTarget(): Promise<void> {
    try {
      await this.padPreferencesService.saveTarget(this.abilityContext(), this.targetIp, this.portText)
    } catch (err) {
      this.statusText = `目标保存失败：${JSON.stringify(err)}`
    }
  }

  private async trustDevice(deviceId?: string, fingerprint?: string): Promise<void> {
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
    } catch (_) {
    }
  }

  private persistBooleanPreference(key: string, value: boolean): void {
    this.padPreferencesService.saveBoolean(this.abilityContext(), key, value)
  }

  private async rememberDevice(device: DeviceInfo): Promise<void> {
    this.persistedDevices = this.persistedDevices
      .filter((item: DeviceInfo) => item.deviceId !== device.deviceId)
      .concat([device])
    await this.transferStore.upsertDevice(device)
  }

  private isTrusted(deviceId?: string): boolean {
    if (!deviceId || deviceId.length === 0) {
      return false
    }
    return this.trustedDeviceIds.indexOf(deviceId) >= 0
  }

  private identityMatches(deviceId?: string, fingerprint?: string): boolean {
    if (!deviceId || !fingerprint || fingerprint.length === 0 || !this.isTrusted(deviceId)) {
      return false
    }
    return this.trustedFingerprints.get(deviceId) === fingerprint
  }

  private runOnUi(task: () => void): void {
    try {
      this.getUIContext().runScopedTask(task)
    } catch (_) {
      task()
    }
  }

  private updateBackgroundTransferActivity(active: boolean): void {
    const context = this.abilityContext()
    if (active) {
      this.backgroundTransferService.begin(context).catch((err: Error) => {
        this.runOnUi(() => {
          this.statusText = `后台传输保护启动失败：${JSON.stringify(err)}`
        })
      })
    } else {
      this.backgroundTransferService.end(context).catch(() => {})
    }
  }

  private abilityContext(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext
  }

  private beginIncomingTransfer(meta: FileMeta): void {
    const historyDeviceId = this.historyDeviceIdForIncoming(meta)
    if (historyDeviceId.length > 0) {
      this.activeTransferDeviceIds.set(meta.transferId, historyDeviceId)
    }
    const existing = this.currentTransfers.filter((row: TransferListItem) => row.id === meta.transferId)
    if (existing.length > 0) {
      return
    }
    const sourceSummary = meta.sourceKind === 'folder' ?
      `${meta.sourceFileCount ?? 0} 个文件 · 原始 ${formatBytes(meta.sourceSize ?? meta.fileSize)}` :
      formatBytes(meta.sourceSize ?? meta.fileSize)
    this.upsertCurrentTransfer({
      id: meta.transferId,
      fileName: meta.fileName,
      peerName: meta.senderName ?? meta.senderPlatform ?? 'Mac',
      direction: '接收',
      progress: 0,
      detail: `等待接收 · ${sourceSummary} · 载荷 ${formatBytes(meta.fileSize)}`,
      state: '传输中',
      timeText: nowText(),
      startedAt: Date.now(),
      fileSize: meta.fileSize,
      fileType: fileTypeLabel(meta.fileName),
      sourceSize: meta.sourceSize ?? meta.fileSize,
      sourceFileCount: meta.sourceFileCount ?? 1,
    })
  }

  // MARK: Receiver and discovery callbacks

  private showIncomingPrompt(meta: FileMeta): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      this.runOnUi(() => {
        const sender = meta.senderName ?? meta.senderPlatform ?? '未知设备'
        this.getUIContext().getPromptAction().showDialog({
          title: `接收来自 ${sender} 的文件？`,
          message: `${meta.fileName}\n大小：${formatBytes(meta.fileSize)}\n首次确认后会信任此设备。`,
          buttons: [
            { text: '拒绝', color: '#64748B' },
            { text: '信任并接收', color: '#2563EB' },
          ],
        }).then((result) => {
          resolve(result.index === 1)
        }).catch((_err: Error) => {
          resolve(false)
        })
      })
    })
  }

  private async ensureReceiverAndDiscovery(): Promise<void> {
    const context = this.abilityContext()
    if (this.receiverEnabled) {
      await this.startReceiver(context)
    } else {
      this.receiverReady = false
      await this.transferService.stopReceive()
    }
    if (this.discoveryEnabled) {
      await this.restartDiscovery()
    } else {
      await this.stopDiscovery()
    }
  }

  private async startReceiver(context: common.UIAbilityContext): Promise<boolean> {
    try {
      await this.transferService.startReceiver(context, this.localTcpPort, {
        onStatus: (value: string) => {
          this.runOnUi(() => {
            this.statusText = value
            if (value.indexOf('接收服务错误') >= 0) {
              this.receiverReady = false
            }
          })
        },
        onProgress: (current: number, total: number, meta?: FileMeta) => {
          this.runOnUi(() => {
            const progressValue = total > 0 ? Math.floor(current / total * 100) : 100
            if (meta) {
              this.beginIncomingTransfer(meta)
              this.updateCurrentTransfer(meta.transferId, progressValue, this.progressDetail(meta.transferId, current, total))
            }
          })
        },
        onReceived: (meta: FileMeta, path: string) => {
          this.runOnUi(() => {
            this.completeTransfer(meta.transferId, true, `已保存到 ${path}`, path)
          })
          this.publishReceivedMedia(meta.transferId, meta.fileName, path).catch((err: Error) => {
            this.runOnUi(() => {
              this.updateHistoryDetail(meta.transferId, `文件打开索引更新失败：${JSON.stringify(err)}`)
            })
          })
        },
        onFailed: (meta: FileMeta, reason: string) => {
          this.runOnUi(() => {
            this.transferStore.recordDiagnostic(this.errorCodeForReason(reason), reason, meta.transferId).catch(() => {})
            this.completeTransfer(meta.transferId, false, this.userMessageForReason(reason))
          })
        },
        onTransferActivity: (active: boolean) => {
          this.updateBackgroundTransferActivity(active)
        },
        onIncoming: async (meta: FileMeta) => {
          if (this.identityMatches(meta.senderDeviceId, meta.senderFingerprint) && this.autoReceiveTrustedEnabled) {
            this.runOnUi(() => {
              this.beginIncomingTransfer(meta)
              this.statusText = `自动接收：${meta.fileName}`
            })
            return true
          }
          if (this.identityMatches(meta.senderDeviceId, meta.senderFingerprint)) {
            return await this.showIncomingPrompt(meta)
          }
          this.runOnUi(() => {
            this.statusText = '已拒绝未配对设备的传输，请先输入六位配对码'
          })
          return false
        },
        onPairing: async (request: PairingRequest) => {
          const expected = this.pairingCode.replace(/\D/g, '')
          const accepted = this.pairingSeconds > 0 &&
            request.code.replace(/\D/g, '') === expected &&
            request.requesterFingerprint !== undefined && request.requesterFingerprint.length > 0
          if (accepted) {
            await this.trustDevice(request.requesterDeviceId, request.requesterFingerprint)
            const pairedDevice: DeviceInfo = {
              app: 'HMTrans',
              version: request.requesterSystemVersion,
              deviceName: request.requesterName,
              platform: request.requesterPlatform,
              ip: request.requesterIP,
              port: request.requesterPort,
              deviceId: request.requesterDeviceId,
              identityFingerprint: request.requesterFingerprint,
            }
            this.deviceLastSeenAt.set(pairedDevice.deviceId, Date.now())
            this.confirmedDeviceLastSeenAt.set(pairedDevice.deviceId, Date.now())
            this.nearbyDevices = this.nearbyDevices
              .filter((item: DeviceInfo) => item.deviceId !== pairedDevice.deviceId)
              .concat([pairedDevice])
            await this.rememberDevice(pairedDevice)
            this.runOnUi(() => {
              this.selectDevice(pairedDevice)
              this.statusText = `已与 ${request.requesterName} 完成配对`
            })
          }
          return accepted
        },
      }, this.receiveDirectory)
      this.receiverReady = true
      this.statusText = '自动发现和接收服务已开启'
      return true
    } catch (err) {
      this.receiverReady = false
      this.transferStore.recordDiagnostic('TRN-RECV-001', JSON.stringify(err)).catch(() => {})
      this.statusText = `接收服务启动失败，可能端口被旧版本占用：${JSON.stringify(err)}`
      return false
    }
  }

  private errorCodeForReason(reason: string): string {
    if (reason.indexOf('insufficient_space') >= 0) return 'STO-SPACE-001'
    if (reason.indexOf('hash_mismatch') >= 0) return 'TRN-HASH-001'
    if (reason.indexOf('archive') >= 0 || reason.indexOf('decompress') >= 0) return 'ARC-UNPACK-001'
    return 'TRN-RECV-002'
  }

  private userMessageForReason(reason: string): string {
    if (reason.indexOf('insufficient_space') >= 0) return '存储空间不足，请清理空间后点击重试'
    if (reason.indexOf('hash_mismatch') >= 0) return '文件校验失败，可由发送端重试'
    if (reason.indexOf('archive') >= 0 || reason.indexOf('decompress') >= 0) return '文件夹归档无效或解压失败'
    return `接收失败：${reason}`
  }

  private async startDiscovery(): Promise<void> {
    if (!this.discoveryEnabled) {
      return
    }
    if (this.discoveryService) {
      return
    }
    this.discoveryService = new DiscoveryService(this.deviceId, this.identityFingerprint)
    try {
      const knownTargets = this.targetIp.length > 0 ? [this.targetIp] : []
      await this.discoveryService.start(this.localDeviceName(), this.localTcpPort, this.discoveryPort, this.networkName,
        this.localSystemVersion(), {
        onDevice: (device: DeviceInfo) => {
          // A packet without an identity fingerprint is unverified, but it is
          // not proof that an already paired device changed identity. Only a
          // concrete, different fingerprint may invalidate local trust.
          if (this.isTrusted(device.deviceId) && device.identityFingerprint &&
            device.identityFingerprint.length > 0 &&
            !this.identityMatches(device.deviceId, device.identityFingerprint)) {
            this.trustedDeviceIds = this.trustedDeviceIds.filter((id: string) => id !== device.deviceId)
            this.trustedFingerprints.delete(device.deviceId)
            this.selectedDeviceIds = this.selectedDeviceIds.filter((id: string) => id !== device.deviceId)
            this.statusText = `设备身份已变化，请重新配对：${device.deviceName}`
            this.transferStore.recordDiagnostic(
              'PAIR-IDENTITY-CHANGED', 'stored fingerprint mismatch'
            ).catch(() => {})
          }
          this.deviceLastSeenAt.set(device.deviceId, Date.now())
          if (device.acknowledgedDeviceId === this.deviceId) {
            this.confirmedDeviceLastSeenAt.set(device.deviceId, Date.now())
          }
          const filtered = this.nearbyDevices.filter((item: DeviceInfo) => item.deviceId !== device.deviceId)
          filtered.push(device)
          filtered.sort((left: DeviceInfo, right: DeviceInfo) => left.deviceName.localeCompare(right.deviceName))
          this.nearbyDevices = filtered

          if (this.isTrusted(device.deviceId)) {
            this.rememberDevice(device).catch(() => {})
          }

          if (device.platform === 'macOS' && this.isTrusted(device.deviceId) &&
            this.isBidirectionallyAlive(device.deviceId)) {
            if (this.selectedDeviceIds.length === 0) {
              this.selectDevice(device)
            } else {
              // Do not silently turn a one-device send into "send to all".
              this.resumeWaitingTransfers(device)
            }
          }
        },
        onStatus: (value: string) => {
          this.statusText = value
        },
      }, knownTargets)
    } catch (err) {
      this.discoveryService = undefined
      this.transferStore.recordDiagnostic('TRN-DISC-001', JSON.stringify(err)).catch(() => {})
      this.statusText = `发现服务启动失败：${JSON.stringify(err)}`
    }
  }

  private startDevicePruning(): void {
    if (this.pruneTimer !== undefined) {
      return
    }
    this.pruneTimer = setInterval(() => {
      this.pruneStaleDevices()
    }, DEVICE_PRUNE_INTERVAL_MS)
  }

  private async restartDiscovery(): Promise<void> {
    await this.refreshNetworkName()
    if (!this.discoveryEnabled) {
      await this.stopDiscovery()
      return
    }
    if (this.discoveryService) {
      await this.discoveryService.stop()
      this.discoveryService = undefined
    }
    this.nearbyDevices = []
    this.deviceLastSeenAt.clear()
    this.confirmedDeviceLastSeenAt.clear()
    if (this.selectedDeviceId.length > 0) {
      this.selectedDeviceId = ''
    }
    await this.startDiscovery()
  }

  private async refreshNetworkName(): Promise<void> {
    try {
      const linkedInfo = await wifiManager.getLinkedInfo()
      this.networkName = linkedInfo.ssid.length > 0 ? linkedInfo.ssid : '未连接 Wi-Fi'
    } catch (_err) {
      this.networkName = '未获取到网络名称'
    }
    try {
      const systemName = settings.getValueSync(this.abilityContext(), settings.general.DEVICE_NAME, '').trim()
      if (systemName.length > 0) this.localDeviceDisplayName = systemName
    } catch (_err) {
    }
  }

  private async stopDiscovery(): Promise<void> {
    if (this.discoveryService) {
      await this.discoveryService.stop()
      this.discoveryService = undefined
    }
    this.nearbyDevices = []
    this.deviceLastSeenAt.clear()
    this.confirmedDeviceLastSeenAt.clear()
    if (this.selectedDeviceId.length > 0) {
      this.selectedDeviceId = ''
    }
  }

  private pruneStaleDevices(): void {
    const now = Date.now()
    const fresh = this.nearbyDevices.filter((device: DeviceInfo) => {
      return now - (this.deviceLastSeenAt.get(device.deviceId) ?? 0) < DEVICE_TTL_MS
    })
    const freshDeviceIds = fresh.map((device: DeviceInfo) => device.deviceId)
    this.deviceLastSeenAt.forEach((_lastSeenAt: number, deviceId: string) => {
      if (freshDeviceIds.indexOf(deviceId) < 0) {
        this.deviceLastSeenAt.delete(deviceId)
      }
    })
    this.confirmedDeviceLastSeenAt.forEach((lastSeenAt: number, deviceId: string) => {
      if (freshDeviceIds.indexOf(deviceId) < 0 || now - lastSeenAt >= DEVICE_TTL_MS) {
        this.confirmedDeviceLastSeenAt.delete(deviceId)
      }
    })
    if (fresh.length !== this.nearbyDevices.length) {
      this.nearbyDevices = fresh
    }
    if (this.selectedDeviceId.length > 0 && !fresh.some((device: DeviceInfo) => device.deviceId === this.selectedDeviceId)) {
      this.selectedDeviceId = ''
    }
    this.selectedDeviceIds = this.selectedDeviceIds.filter((deviceId: string) => {
      return fresh.some((device: DeviceInfo) => device.deviceId === deviceId) &&
        this.isBidirectionallyAlive(deviceId)
    })
  }

  private selectDevice(device: DeviceInfo): void {
    if (!this.isTrusted(device.deviceId)) {
      this.beginPairing(device)
      return
    }
    this.selectedDeviceId = device.deviceId
    if (this.selectedDeviceIds.indexOf(device.deviceId) < 0) {
      this.selectedDeviceIds = this.selectedDeviceIds.concat([device.deviceId])
    }
    this.targetIp = device.ip
    this.portText = `${device.port}`
    this.statusText = `已自动连接：${device.deviceName}`
    this.saveTarget()
    this.resumeWaitingTransfers(device)
  }

  /** Connected means the peer explicitly acknowledged this Pad, not merely that one broadcast was heard. */
  private isBidirectionallyAlive(deviceId: string): boolean {
    return Date.now() - (this.confirmedDeviceLastSeenAt.get(deviceId) ?? 0) < DEVICE_TTL_MS
  }

  // MARK: Pairing and transfer target selection

  private toggleTransferTarget(device: DeviceInfo): void {
    if (!this.isTrusted(device.deviceId)) {
      this.beginPairing(device)
      return
    }
    const selected = this.selectedDeviceIds.indexOf(device.deviceId) >= 0
    if (selected && this.selectedDeviceIds.length > 1) {
      this.selectedDeviceIds = this.selectedDeviceIds.filter((id: string) => id !== device.deviceId)
      this.statusText = `已取消选择：${device.deviceName}`
      return
    }
    if (!selected) {
      this.selectedDeviceIds = this.selectedDeviceIds.concat([device.deviceId])
    }
    this.selectedDeviceId = device.deviceId
    this.targetIp = device.ip
    this.portText = `${device.port}`
    this.statusText = `已选择发送目标：${device.deviceName}`
  }

  private resumeWaitingTransfers(device: DeviceInfo): void {
    const candidates = this.currentTransfers.filter((item: TransferListItem) => {
      const hasSource = this.archiveService.sourceExists(item.stagingPath)
      return item.direction === '发送' && item.state === '等待重连' && hasSource &&
        (item.deviceId.length === 0 || item.deviceId === device.deviceId ||
          item.peerName === device.deviceName) && !this.activeTransferDeviceIds.has(item.id)
    })
    candidates.forEach((item: TransferListItem) => {
      this.activeTransferDeviceIds.set(item.id, device.deviceId)
      this.markCurrentTransferState(item.id, '准备中', '设备已恢复，正在协商断点')
      this.resumeTransferItem(item, device).catch((err: Error) => {
        this.runOnUi(() => {
          this.activeTransferDeviceIds.delete(item.id)
          const detail = JSON.stringify(err)
          if (detail.indexOf('Persistent staging source is missing') >= 0 || detail.indexOf('13900002') >= 0) {
            this.completeTransfer(item.id, false, '源文件不可用，请重新选择文件发送')
          } else {
            this.markCurrentTransferState(item.id, '等待重连', '网络仍未恢复，稍后自动重试')
          }
        })
      })
    })
  }

  private async resumeTransferItem(item: TransferListItem, device: DeviceInfo): Promise<void> {
    if (!this.archiveService.sourceExists(item.stagingPath)) {
      throw new Error('Persistent staging source is missing')
    }
    const source = this.archiveService.restore(item.stagingPath ?? '', item.localPath, item.fileName,
      item.fileSize, item.fileType, item.sourceSize, item.sourceFileCount)
    await this.sendPreparedSource(source, device, item.id, item.groupId)
  }

  private beginPairing(device: DeviceInfo): void {
    if (!device.identityFingerprint || device.identityFingerprint.length === 0) {
      this.statusText = '对端版本过旧或身份信息缺失，请将两端升级到 v0.2 后重新配对'
      return
    }
    this.pairingTarget = device
    this.pairingInput = ''
    this.statusText = `等待输入 ${device.deviceName} 的六位配对码`
  }

  private reconnectTrustedDevice(device: DeviceInfo): void {
    if (!this.discoveryEnabled) {
      this.statusText = '请先开启连接服务'
      return
    }
    this.targetIp = device.ip
    this.portText = `${device.port}`
    this.statusText = `正在重新连接：${device.deviceName}`
    this.saveTarget()
    this.restartDiscovery().catch((err: Error) => {
      this.statusText = `重新连接失败：${JSON.stringify(err)}`
    })
  }

  private async submitPairing(): Promise<void> {
    const device = this.pairingTarget
    if (!device || this.pairingInput.length !== 6) {
      this.statusText = '请输入六位配对码'
      return
    }
    try {
      this.statusText = `正在校验 ${device.deviceName} 的配对码`
      const request = createPairingRequest(
        this.deviceId,
        this.localDeviceName(),
        'HarmonyOS',
        this.localSystemVersion(),
        '0.0.0.0',
        this.localTcpPort,
        this.pairingInput,
        this.identityFingerprint
      )
      const response = await this.transferService.requestPairing(device.ip, device.port, request)
      if (!response.accepted) {
        this.statusText = '配对失败：配对码错误或已过期'
        return
      }
      await this.trustDevice(device.deviceId, device.identityFingerprint)
      this.confirmedDeviceLastSeenAt.set(device.deviceId, Date.now())
      await this.rememberDevice(device)
      this.pairingTarget = undefined
      this.pairingInput = ''
      this.selectDevice(device)
      this.statusText = `配对成功：${device.deviceName}`
    } catch (err) {
      this.statusText = `配对失败：${JSON.stringify(err)}`
    }
  }

  @Computed
  private get connectionTitle(): string {
    const device = this.selectedDevice
    if (device) {
      return device.deviceName
    }
    if (this.targetIp.length > 0) {
      return this.targetIp
    }
    return '未连接设备'
  }

  @Computed
  private get selectedDevice(): DeviceInfo | undefined {
    const matched = this.connectedDevices.filter((device: DeviceInfo) => device.deviceId === this.selectedDeviceId)
    return matched.length > 0 ? matched[0] : undefined
  }

  @Computed
  private get freshDevices(): Array<DeviceInfo> {
    const now = Date.now()
    return this.nearbyDevices.filter((device: DeviceInfo) => {
      return now - (this.deviceLastSeenAt.get(device.deviceId) ?? 0) < DEVICE_TTL_MS
    })
  }

  @Computed
  private get port(): number {
    const value = Number(this.portText)
    return Number.isFinite(value) && value > 0 ? value : DEFAULT_PORT
  }

  @Computed
  private get localTcpPort(): number {
    const value = Number(this.localTcpPortText)
    return Number.isInteger(value) && value > 0 && value <= 65535 ? value : DEFAULT_PORT
  }

  @Computed
  private get discoveryPort(): number {
    const value = Number(this.discoveryPortText)
    return Number.isInteger(value) && value > 0 && value <= 65535 ? value : DISCOVERY_PORT
  }

  private localDeviceName(): string {
    if (this.localDeviceDisplayName.length > 0) {
      return this.localDeviceDisplayName
    }
    const fallback = deviceInfo.marketName && deviceInfo.marketName.length > 0 ? deviceInfo.marketName :
      (deviceInfo.productModel && deviceInfo.productModel.length > 0 ? deviceInfo.productModel : 'HarmonyOS-Device')
    return fallback
  }

  /** Advertises the user-facing HarmonyOS version instead of the OpenHarmony build string. */
  private localSystemVersion(): string {
    const value = deviceInfo.displayVersion.trim()
    const version = value.match(/\d+(?:\.\d+){2,3}/)?.[0] ?? value
    const servicePack = value.match(/SP\d+/i)?.[0]?.toUpperCase() ?? ''
    return `HarmonyOS${version}${servicePack.length > 0 ? ` ${servicePack}` : ''}`
  }

  private async selectAndSendFile(): Promise<void> {
    if (this.connectedDevices.length === 0) {
      this.statusText = '请等待发现并选择 Mac'
      return
    }

    try {
      const context = this.abilityContext()
      const documentPicker = new picker.DocumentViewPicker(context)
      const options: picker.DocumentSelectOptions = { maxSelectNumber: 50 }
      if (canIUse('SystemCapability.FileManagement.UserFileService.FolderSelection')) {
        options.selectMode = picker.DocumentSelectMode.MIXED
      }
      const uris = await documentPicker.select(options)
      if (uris.length === 0) {
        this.statusText = '未选择文件'
        return
      }

      await this.sendUris(uris)
    } catch (err) {
      this.statusText = `发送失败：${JSON.stringify(err)}`
    }
  }

  // MARK: Outgoing sessions and UI task controls

  private async sendUris(uris: Array<string>): Promise<void> {
    const selectedTargets = this.connectedDevices.filter((device: DeviceInfo) => {
      return this.selectedDeviceIds.indexOf(device.deviceId) >= 0
    })
    const targets = selectedTargets.length > 0 ? selectedTargets : this.connectedDevices
    if (targets.length === 0) {
      this.statusText = '请等待发现并选择 Mac'
      return
    }

    await this.outgoingCoordinator.sendUris(uris, targets, this.abilityContext(), {
      deviceId: this.deviceId, deviceName: this.localDeviceName(), fingerprint: this.identityFingerprint,
    }, this.outgoingCallbacks())
  }

  /** Keeps the connection page send area usable when only one live target exists. */
  private transferTargetLabel(): string {
    if (this.selectedDeviceIds.length > 1) return `${this.selectedDeviceIds.length} 台设备`
    if (this.selectedDevice) return this.selectedDevice.deviceName
    if (this.connectedDevices.length === 1) return this.connectedDevices[0].deviceName
    if (this.connectedDevices.length > 1) return `${this.connectedDevices.length} 台设备`
    return ''
  }

  private async sendPreparedSource(source: SendableSource, device: DeviceInfo, reuseTransferId?: string,
    groupId?: string, cleanupSource: boolean = true): Promise<boolean> {
    const transferId = reuseTransferId ?? `${Date.now()}-${Math.floor(Math.random() * 100000)}`
    return await this.outgoingCoordinator.sendPrepared(source, device, {
      deviceId: this.deviceId, deviceName: this.localDeviceName(), fingerprint: this.identityFingerprint,
    }, this.outgoingCallbacks(), transferId, groupId, cleanupSource)
  }

  private outgoingCallbacks(): OutgoingTransferCallbacks {
    return {
      onStatus: (value: string) => this.runOnUi(() => { this.statusText = value }),
      onBegin: (options: TransferListItemOptions, deviceId: string) => this.runOnUi(() => {
        this.activeTransferDeviceIds.set(options.id, deviceId)
        if (this.currentTransfers.some((item: TransferListItem) => item.id === options.id)) {
          this.markCurrentTransferState(options.id, '准备中', '正在协商断点')
        } else {
          options.timeText = nowText()
          this.upsertCurrentTransfer(options)
        }
      }),
      onProgress: (id: string, current: number, total: number) => this.runOnUi(() => {
        const progressValue = total > 0 ? Math.floor(current / total * 100) : 100
        this.updateCurrentTransfer(id, progressValue, this.progressDetail(id, current, total))
      }),
      onComplete: (id: string) => this.runOnUi(() => this.completeTransfer(id, true, '发送完成')),
      onPermanentFailure: (id: string, detail: string) => this.runOnUi(() => {
        this.statusText = `发送失败：${detail}`
        this.transferStore.recordDiagnostic('TRN-SEND-001', detail, id).catch(() => {})
        this.completeTransfer(id, false, `发送失败：${detail}`)
      }),
      onWaiting: (id: string, _detail: string) => this.runOnUi(() => {
        this.activeTransferDeviceIds.delete(id)
        this.markCurrentTransferState(id, '等待重连', '连接中断，已保存断点')
        this.scheduleAutomaticResume(id)
      }),
      onActivity: (active: boolean) => this.updateBackgroundTransferActivity(active),
      onPreparationFailure: (options: TransferListItemOptions, deviceId: string, detail: string) => this.runOnUi(() => {
        this.activeTransferDeviceIds.set(options.id, deviceId); options.timeText = nowText()
        this.upsertCurrentTransfer(options); this.completeTransfer(options.id, false, detail)
      }),
      isSourceReferenced: (path: string) => this.currentTransfers.some((item: TransferListItem) =>
        item.stagingPath === path),
    }
  }

  private handleDrop(event: DragEvent): void {
    try {
      const uris = this.dropUriService.extract(event)
      if (uris.length === 0) {
        this.statusText = '拖拽内容没有可读取的文件地址'
        return
      }
      this.sendUris(uris)
    } catch (err) {
      this.statusText = `拖拽读取失败：${JSON.stringify(err)}`
    }
  }

  private upsertCurrentTransfer(item: TransferListItemOptions): void {
    this.currentTransfers = this.transferStateService.upsert(this.currentTransfers, item,
      this.activeTransferDeviceIds.get(item.id) ?? this.selectedDeviceId)
    this.persistTransferState(true)
  }

  private updateCurrentTransfer(id: string, progress: number, detail: string): void {
    this.transferStateService.updateProgress(this.currentTransfers, id, progress, detail)
    this.persistTransferState()
  }

  private toggleTransferPause(item: TransferListItem): void {
    if (item.direction === '接收') {
      if (item.state === '已暂停') {
        this.transferService.resumeTransfer(item.id)
        this.markCurrentTransferState(item.id, '等待重连', '接收已恢复，等待发送端重连')
      } else {
        this.transferService.pauseTransfer(item.id)
        this.markCurrentTransferState(item.id, '已暂停', '接收已暂停，分片已保留')
      }
      return
    }
    if (item.state === '等待重连') {
      const matched = this.freshDevices.filter((device: DeviceInfo) => device.deviceId === item.deviceId)
      const device = matched.length > 0 ? matched[0] : this.selectedDevice
      if (!device) {
        this.statusText = `请先重新连接 ${item.peerName}`
        return
      }
      this.resumeWaitingTransfers(device)
      return
    }
    if (item.state === '已暂停') {
      this.transferService.resumeTransfer(item.id)
      this.markCurrentTransferState(item.id, '传输中', '正在继续传输')
    } else {
      this.transferService.pauseTransfer(item.id)
      this.markCurrentTransferState(item.id, '已暂停', '已暂停网络发送')
    }
  }

  /** Applies one control decision to every independent child in a multicast group. */
  private toggleTransferGroup(item: TransferListItem): void {
    const rows = this.currentTransfers.filter((row: TransferListItem) => row.groupId === item.groupId)
    const shouldPause = rows.some((row: TransferListItem) => row.state !== '已暂停' && row.state !== '等待重连')
    rows.forEach((row: TransferListItem) => {
      if (shouldPause && row.state !== '已暂停' && row.state !== '等待重连') {
        this.toggleTransferPause(row)
      } else if (!shouldPause && (row.state === '已暂停' || row.state === '等待重连')) {
        this.toggleTransferPause(row)
      }
    })
  }

  private cancelTransfer(item: TransferListItem): void {
    this.transferService.cancelTransfer(item.id)
    this.activeTransferDeviceIds.delete(item.id)
    this.currentTransfers = this.currentTransfers.filter((row: TransferListItem) => row.id !== item.id)
    const cancelled = item.copyWith(item.progress, '用户取消', '已取消', nowText())
    this.appendHistory(cancelled, item.deviceId.length > 0 ? item.deviceId : this.selectedDeviceId)
  }

  private confirmCancelTransfer(item: TransferListItem): void {
    this.getUIContext().getPromptAction().showDialog({
      title: '取消传输？',
      message: '可以保留私有分片以便稍后恢复，或同时删除该任务的可恢复数据。',
      buttons: [
        { text: '返回', color: '#64748B' },
        { text: '取消并保留', color: '#2563EB' },
        { text: '取消并删除', color: '#C2413A' },
      ],
    }).then((result) => {
      if (result.index === 1 || result.index === 2) {
        this.cancelTransfer(item)
        if (result.index === 2) this.deleteRecoverableArtifact(item)
      }
    }).catch(() => {})
  }

  private confirmCancelTransferGroup(item: TransferListItem): void {
    const rows = this.currentTransfers.filter((row: TransferListItem) => row.groupId === item.groupId)
    this.getUIContext().getPromptAction().showDialog({
      title: `取消整组 ${rows.length} 个任务？`,
      message: '每台设备的任务会分别取消，可以保留或删除共享的可恢复数据。',
      buttons: [
        { text: '返回', color: '#64748B' },
        { text: '取消并保留', color: '#2563EB' },
        { text: '取消并删除', color: '#C2413A' },
      ],
    }).then((result) => {
      if (result.index !== 1 && result.index !== 2) return
      rows.forEach((row: TransferListItem) => {
        this.cancelTransfer(row)
        if (result.index === 2) this.deleteRecoverableArtifact(row)
      })
    }).catch(() => {})
  }

  private deleteRecoverableArtifact(item: TransferListItem): void {
    const stagingRoot = `${this.abilityContext().filesDir}/HMTrans/Staging`
    this.stagingStorageService.removeRecursively(`${stagingRoot}/${item.id}.part`)
    this.stagingStorageService.removeRecursively(`${stagingRoot}/${item.id}.meta.json`)
    const source = item.stagingPath
    if (source && !this.currentTransfers.some((row: TransferListItem) => row.stagingPath === source)) {
      this.stagingStorageService.removeRecursively(source)
    }
  }

  private markCurrentTransferState(id: string, state: string, detail: string): void {
    this.transferStateService.mark(this.currentTransfers, id, state, detail)
    this.persistTransferState(true)
  }

  private scheduleAutomaticResume(id: string): void {
    setTimeout(() => {
      const matched = this.currentTransfers.filter((item: TransferListItem) => {
        return item.id === id && item.state === '等待重连'
      })
      const device = this.selectedDevice
      if (matched.length > 0 && device && !this.activeTransferDeviceIds.has(id)) {
        this.resumeWaitingTransfers(device)
      }
    }, 2000)
  }

  private completeTransfer(id: string, success: boolean, detail: string, localPath?: string): void {
    const historyDeviceId = this.activeTransferDeviceIds.get(id) ?? this.selectedDeviceId
    this.activeTransferDeviceIds.delete(id)
    const result = this.transferStateService.complete(this.currentTransfers, id, success, detail, localPath,
      historyDeviceId)
    this.currentTransfers = result.current
    if (result.historyItem) this.appendHistory(result.historyItem, historyDeviceId)
  }

  // MARK: Durable history and progress formatting

  private appendHistory(item: TransferListItem, deviceId: string): void {
    if (deviceId.length === 0) {
      return
    }
    // 历史记录只允许用户主动删除；不能用数量上限静默丢失旧记录。
    this.historyTransfers = this.transferStateService.appendHistory(this.historyTransfers, item, deviceId)
    this.persistTransferState(true)
  }

  private historyDeviceIdForIncoming(meta: FileMeta): string {
    if (this.selectedDeviceId.length > 0 && this.selectedDevice !== undefined) {
      return this.selectedDeviceId
    }
    return meta.senderDeviceId ?? ''
  }

  private async publishReceivedMedia(transferId: string, _fileName: string, _path: string): Promise<void> {
    this.runOnUi(() => {
      this.updateHistoryDetail(transferId, '已保存到下载目录 HMTrans')
    })
  }

  private updateHistoryDetail(id: string, detailPrefix: string): void {
    this.updateHistoryItem(id, detailPrefix)
  }

  private updateHistoryItem(id: string, detailPrefix: string): void {
    this.historyTransfers = this.transferStateService.updateHistory(this.historyTransfers, id, detailPrefix)
    this.persistTransferState(true)
  }

  private progressDetail(id: string, current: number, total: number): string {
    if (total <= 0) {
      return '传输中'
    }
    const matched = this.currentTransfers.filter((row: TransferListItem) => row.id === id)
    const startedAt = matched.length > 0 ? matched[0].startedAt : Date.now()
    const elapsed = Math.max((Date.now() - startedAt) / 1000, 0.15)
    const speed = current / elapsed
    return `${formatBytes(current)} / ${formatBytes(total)} · ${formatBytes(speed)}/s`
  }

}
