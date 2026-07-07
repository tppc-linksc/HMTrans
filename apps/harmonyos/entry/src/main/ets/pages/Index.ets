import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit'
import { preferences, unifiedDataChannel, uniformTypeDescriptor } from '@kit.ArkData'
import { deviceInfo } from '@kit.BasicServicesKit'
import { Environment, fileIo as fs, picker } from '@kit.CoreFileKit'
import { DEFAULT_PORT, DeviceInfo, FileMeta } from '../common/Protocol'
import { completionDetail, fileNameFromUri, fileTypeLabel, formatBytes, nowText } from '../common/Formatters'
import { TransferListItem, TransferListItemOptions } from '../models/TransferListItem'
import { DeviceStrip } from '../components/DeviceStrip'
import { TransferPane } from '../components/TransferPane'
import { ArchiveService, SendableSource } from '../services/ArchiveService'
import { DiscoveryService } from '../services/DiscoveryService'
import { TcpTransferService } from '../services/TcpTransferService'

const DEVICE_TTL_MS: number = 5000
const DEVICE_PRUNE_INTERVAL_MS: number = 1000
const PREFERENCES_NAME: string = 'HMTrans'
const DOWNLOAD_PERMISSION: Permissions = 'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY'

@Entry
@ComponentV2
struct Index {
  @Local targetIp: string = ''
  @Local portText: string = `${DEFAULT_PORT}`
  @Local statusText: string = '正在启动 HM互传'
  @Local progressValue: number = 0
  @Local receiverText: string = '接收启动中'
  @Local nearbyDevices: Array<DeviceInfo> = []
  @Local selectedDeviceId: string = ''
  @Local trustedDeviceIds: Array<string> = []
  @Local currentTransfers: Array<TransferListItem> = []
  @Local historyTransfers: Array<TransferListItem> = []
  @Local compactLayout: boolean = false
  private transferService: TcpTransferService = new TcpTransferService()
  private archiveService: ArchiveService = new ArchiveService()
  private discoveryService?: DiscoveryService
  private bootstrapped: boolean = false
  private deviceId: string = ''
  private deviceLastSeenAt: Map<string, number> = new Map()
  private historyTransfersByDevice: Map<string, Array<TransferListItem>> = new Map()
  private activeTransferDeviceIds: Map<string, string> = new Map()
  private receiveDirectory: string = ''
  private receiverReady: boolean = false
  private pruneTimer?: number

  aboutToAppear(): void {
    if (this.bootstrapped) {
      return
    }
    this.bootstrapped = true
    this.bootstrap()
  }

  onPageShow(): void {
    if (!this.bootstrapped) {
      return
    }
    this.startDevicePruning()
    this.statusText = this.selectedDevice ? this.statusText : '正在重新发现设备'
    this.ensureReceiverAndDiscovery().catch((err: Error) => {
      this.statusText = `服务恢复失败：${JSON.stringify(err)}`
    })
  }

  build() {
    if (this.compactLayout) {
      Scroll() {
        this.PageContent(false)
      }
      .width('100%')
      .height('100%')
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Off)
      .backgroundColor('#F6FBFF')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .onAreaChange((_oldArea, newArea) => {
        const width = Number.parseFloat(`${newArea.width}`)
        this.compactLayout = Number.isFinite(width) && width < 760
      })
    } else {
      Column() {
        this.PageContent(true)
      }
        .width('100%')
        .height('100%')
        .backgroundColor('#F6FBFF')
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .onAreaChange((_oldArea, newArea) => {
          const width = Number.parseFloat(`${newArea.width}`)
          this.compactLayout = Number.isFinite(width) && width < 760
        })
    }
  }

  @Builder
  private PageContent(stretch: boolean) {
    if (stretch) {
      Column({ space: 14 }) {
        this.Header()
        this.FileDropSection()
        DeviceStrip({
          devices: this.freshDevices,
          selectedDeviceId: this.selectedDeviceId,
          onDeviceSelected: (device: DeviceInfo) => {
            this.selectDevice(device)
          },
        })
        this.FileWorkspace(true)
      }
      .width('100%')
      .height('100%')
      .padding({ left: 24, right: 24, top: 34, bottom: 22 })
    } else {
      Column({ space: 14 }) {
        this.Header()
        this.FileDropSection()
        DeviceStrip({
          devices: this.freshDevices,
          selectedDeviceId: this.selectedDeviceId,
          onDeviceSelected: (device: DeviceInfo) => {
            this.selectDevice(device)
          },
        })
        this.FileWorkspace(false)
      }
      .width('100%')
      .padding({ left: 24, right: 24, top: 34, bottom: 22 })
    }
  }

  @Builder
  private Header() {
    Row() {
      if (this.selectedDevice) {
        Row({ space: 8 }) {
          Text(this.connectionTitle)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#172033')
          Text(this.selectedDevice?.ip ?? '')
            .fontSize(13)
            .fontColor('#64748B')
          Text('connected')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#16A34A')
        }
      } else {
        Text('unconnected')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#64748B')
      }
    }
    .width('100%')
    .height(28)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  private FileDropSection() {
    Column({ space: 10 }) {
      Text('+')
        .fontSize(42)
        .fontWeight(FontWeight.Regular)
        .fontColor('#2563EB')
        .textAlign(TextAlign.Center)
        .width(60)
        .height(60)
        .backgroundColor($r('app.color.app_action_surface'))
        .borderRadius(30)
        .shadow({ radius: 18, color: '#DCEAF8', offsetY: 9 })
      Text(this.selectedDevice ? '点击选择文件并发送' : '等待自动发现 Mac')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor('#111827')
        .textAlign(TextAlign.Center)
        .maxLines(2)
        .width('92%')
      Text(this.selectedDevice ? '同一 Wi-Fi 下原文件直传，支持任意文件类型' : '保持 Mac 端 HMTrans 打开')
        .fontSize(12)
        .fontColor('#64748B')
        .textAlign(TextAlign.Center)
        .maxLines(2)
        .width('92%')
    }
    .width('100%')
    .height(220)
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#F8FCFF')
    .borderRadius(24)
    .border({
      width: 2,
      color: '#7FB4F8',
      style: BorderStyle.Dashed,
    })
    .shadow({ radius: 24, color: '#E4EEF8', offsetY: 10 })
    .enabled(this.selectedDevice !== undefined)
    .onClick(() => {
      this.selectAndSendFile()
    })
    .allowDrop([
      uniformTypeDescriptor.UniformDataType.FILE,
      uniformTypeDescriptor.UniformDataType.FOLDER,
      uniformTypeDescriptor.UniformDataType.FILE_URI,
    ])
    .onDrop((event: DragEvent) => {
      this.handleDrop(event)
    })
  }

  @Builder
  private FileWorkspace(stretch: boolean) {
    Flex({
      direction: this.compactLayout ? FlexDirection.Column : FlexDirection.Row,
      wrap: this.compactLayout ? FlexWrap.NoWrap : FlexWrap.Wrap,
      justifyContent: FlexAlign.SpaceBetween,
    }) {
      TransferPane({
        title: '当前传输',
        iconKind: 'current',
        items: this.currentTransfers,
        emptyTitle: '暂无正在传输的文件',
        emptySubtitle: '点击上方区域选择文件，或等待 Mac 发送文件',
        compactLayout: this.compactLayout,
        fillHeight: stretch && !this.compactLayout,
      })
      TransferPane({
        title: '历史记录',
        iconKind: 'history',
        items: this.historyTransfers,
        emptyTitle: '暂无历史记录',
        emptySubtitle: '完成或失败的传输会显示在这里',
        compactLayout: this.compactLayout,
        fillHeight: stretch && !this.compactLayout,
      })
    }
    .width('100%')
    .layoutWeight(stretch ? 1 : 0)
    .constraintSize({ minHeight: stretch ? 0 : 360 })
  }

  private async bootstrap(): Promise<void> {
    const context = this.abilityContext()
    await this.loadPreferences(context)
    await this.prepareReceiveDirectory(context)
    await this.ensureReceiverAndDiscovery()
    this.startDevicePruning()
  }

  private async prepareReceiveDirectory(context: common.UIAbilityContext): Promise<void> {
    try {
      const atManager = abilityAccessCtrl.createAtManager()
      const permissionResult = await atManager.requestPermissionsFromUser(context, [DOWNLOAD_PERMISSION])
      if (permissionResult.authResults.length === 0 || permissionResult.authResults[0] !== 0) {
        this.statusText = '未授权下载目录，接收服务未启动'
        return
      }
      if (canIUse('SystemCapability.FileManagement.UserFileService')) {
        const downloadDir = Environment.getUserDownloadDir()
        const receiveDir = `${downloadDir}/HMTrans`
        try {
          fs.mkdirSync(receiveDir)
        } catch (_) {
        }
        this.verifyWritableDirectory(receiveDir)
        this.receiveDirectory = receiveDir
        this.statusText = `接收目录：${receiveDir}`
      } else {
        this.statusText = '当前设备不支持下载目录能力，接收服务未启动'
        return
      }
    } catch (err) {
      this.receiveDirectory = ''
      this.statusText = `下载目录初始化失败：${JSON.stringify(err)}`
    }
  }

  private verifyWritableDirectory(directory: string): void {
    const testPath = `${directory}/.hmtrans-write-test`
    let file: fs.File | undefined
    try {
      file = fs.openSync(testPath, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE)
    } catch (err) {
      throw new Error(`接收目录不可写：${JSON.stringify(err)}`)
    } finally {
      if (file) {
        try {
          fs.closeSync(file)
        } catch (_) {
        }
      }
      try {
        fs.unlinkSync(testPath)
      } catch (_) {
      }
    }
  }

  private async loadPreferences(context: common.UIAbilityContext): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, PREFERENCES_NAME)
      const savedHost = await store.get('lastHost', '') as string
      const savedPort = await store.get('lastPort', `${DEFAULT_PORT}`) as string
      const savedDeviceId = await store.get('deviceId', '') as string
      const trusted = await store.get('trustedDeviceIds', '') as string

      this.targetIp = savedHost
      this.portText = savedPort
      this.trustedDeviceIds = trusted.length > 0 ? trusted.split(',') : []
      this.deviceId = savedDeviceId.length > 0 ? savedDeviceId : `pad-${Date.now()}-${Math.floor(Math.random() * 100000)}`

      if (savedDeviceId.length === 0) {
        await store.put('deviceId', this.deviceId)
        await store.flush()
      }
      this.refreshHistoryForSelectedDevice()
    } catch (err) {
      this.deviceId = `pad-${Date.now()}-${Math.floor(Math.random() * 100000)}`
      this.statusText = `偏好读取失败：${JSON.stringify(err)}`
      this.refreshHistoryForSelectedDevice()
    }
  }

  private async saveTarget(): Promise<void> {
    try {
      const context = this.abilityContext()
      const store = await preferences.getPreferences(context, PREFERENCES_NAME)
      await store.put('lastHost', this.targetIp)
      await store.put('lastPort', this.portText)
      await store.flush()
    } catch (err) {
      this.statusText = `目标保存失败：${JSON.stringify(err)}`
    }
  }

  private async trustDevice(deviceId?: string): Promise<void> {
    if (!deviceId || deviceId.length === 0 || this.trustedDeviceIds.indexOf(deviceId) >= 0) {
      return
    }
    this.trustedDeviceIds = this.trustedDeviceIds.concat([deviceId])
    try {
      const context = this.abilityContext()
      const store = await preferences.getPreferences(context, PREFERENCES_NAME)
      await store.put('trustedDeviceIds', this.trustedDeviceIds.join(','))
      await store.flush()
    } catch (_) {
    }
  }

  private isTrusted(deviceId?: string): boolean {
    if (!deviceId || deviceId.length === 0) {
      return false
    }
    return this.trustedDeviceIds.indexOf(deviceId) >= 0
  }

  private runOnUi(task: () => void): void {
    try {
      this.getUIContext().runScopedTask(task)
    } catch (_) {
      task()
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
    this.upsertCurrentTransfer({
      id: meta.transferId,
      fileName: meta.fileName,
      peerName: meta.senderName ?? meta.senderPlatform ?? 'Mac',
      direction: '接收',
      progress: 0,
      detail: `等待接收 · ${formatBytes(meta.fileSize)} · ${fileTypeLabel(meta.fileName)}`,
      state: '传输中',
      timeText: nowText(),
      startedAt: Date.now(),
      fileSize: meta.fileSize,
      fileType: fileTypeLabel(meta.fileName),
    })
  }

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
    const ready = await this.startReceiver(context)
    if (!ready) {
      await this.stopDiscovery()
      return
    }
    await this.restartDiscovery()
  }

  private async startReceiver(context: common.UIAbilityContext): Promise<boolean> {
    try {
      await this.transferService.startReceiver(context, this.port, {
        onStatus: (value: string) => {
          this.runOnUi(() => {
            this.statusText = value
            if (value.indexOf('接收服务错误') >= 0) {
              this.receiverReady = false
              this.stopDiscovery().catch(() => {})
            }
          })
        },
        onProgress: (current: number, total: number, meta?: FileMeta) => {
          this.runOnUi(() => {
            this.progressValue = total > 0 ? Math.floor(current / total * 100) : 100
            if (meta) {
              this.beginIncomingTransfer(meta)
              this.updateCurrentTransfer(meta.transferId, this.progressValue, this.progressDetail(meta.transferId, current, total))
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
        onIncoming: async (meta: FileMeta) => {
          if (this.isTrusted(meta.senderDeviceId)) {
            this.runOnUi(() => {
              this.beginIncomingTransfer(meta)
              this.statusText = `自动接收：${meta.fileName}`
            })
            return true
          }

          const accepted = await this.showIncomingPrompt(meta)
          if (accepted) {
            await this.trustDevice(meta.senderDeviceId)
            this.runOnUi(() => {
              this.beginIncomingTransfer(meta)
            })
          }
          return accepted
        },
      }, this.receiveDirectory)
      this.receiverReady = true
      this.receiverText = `接收中 :${this.port}`
      this.statusText = '自动发现和接收服务已开启'
      return true
    } catch (err) {
      this.receiverReady = false
      this.receiverText = '接收异常'
      this.statusText = `接收服务启动失败，可能端口被旧版本占用：${JSON.stringify(err)}`
      return false
    }
  }

  private async startDiscovery(): Promise<void> {
    if (this.discoveryService) {
      return
    }
    this.discoveryService = new DiscoveryService(this.deviceId)
    try {
      const knownTargets = this.targetIp.length > 0 ? [this.targetIp] : []
      await this.discoveryService.start(this.localDeviceName(), this.port, {
        onDevice: (device: DeviceInfo) => {
          this.deviceLastSeenAt.set(device.deviceId, Date.now())
          const filtered = this.nearbyDevices.filter((item: DeviceInfo) => item.deviceId !== device.deviceId)
          filtered.push(device)
          filtered.sort((left: DeviceInfo, right: DeviceInfo) => left.deviceName.localeCompare(right.deviceName))
          this.nearbyDevices = filtered

          if (device.platform === 'macOS' &&
            (this.selectedDeviceId.length === 0 ||
              this.selectedDeviceId === device.deviceId ||
              this.targetIp.length === 0 ||
              this.targetIp === device.ip ||
              this.trustedDeviceIds.indexOf(device.deviceId) >= 0)) {
            this.selectDevice(device)
          }
        },
        onStatus: (value: string) => {
          this.statusText = value
        },
      }, knownTargets)
    } catch (err) {
      this.discoveryService = undefined
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
    if (!this.receiverReady) {
      await this.stopDiscovery()
      return
    }
    if (this.discoveryService) {
      await this.discoveryService.stop()
      this.discoveryService = undefined
    }
    this.nearbyDevices = []
    this.deviceLastSeenAt.clear()
    if (this.selectedDeviceId.length > 0) {
      this.selectedDeviceId = ''
      this.refreshHistoryForSelectedDevice()
    }
    await this.startDiscovery()
  }

  private async stopDiscovery(): Promise<void> {
    if (this.discoveryService) {
      await this.discoveryService.stop()
      this.discoveryService = undefined
    }
    this.nearbyDevices = []
    this.deviceLastSeenAt.clear()
    if (this.selectedDeviceId.length > 0) {
      this.selectedDeviceId = ''
      this.refreshHistoryForSelectedDevice()
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
    if (fresh.length !== this.nearbyDevices.length) {
      this.nearbyDevices = fresh
    }
    if (this.selectedDeviceId.length > 0 && !fresh.some((device: DeviceInfo) => device.deviceId === this.selectedDeviceId)) {
      this.selectedDeviceId = ''
      this.refreshHistoryForSelectedDevice()
    }
  }

  private selectDevice(device: DeviceInfo): void {
    this.selectedDeviceId = device.deviceId
    this.targetIp = device.ip
    this.portText = `${device.port}`
    this.statusText = `已自动连接：${device.deviceName}`
    this.refreshHistoryForSelectedDevice()
    this.saveTarget()
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
    const matched = this.freshDevices.filter((device: DeviceInfo) => device.deviceId === this.selectedDeviceId)
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

  private localDeviceName(): string {
    if (deviceInfo.marketName && deviceInfo.marketName.length > 0) {
      return deviceInfo.marketName
    }
    if (deviceInfo.productModel && deviceInfo.productModel.length > 0) {
      return deviceInfo.productModel
    }
    return 'HarmonyOS-Device'
  }

  private async selectAndSendFile(): Promise<void> {
    const device = this.selectedDevice
    if (!device) {
      this.statusText = '请等待发现并选择 Mac'
      return
    }

    try {
      const context = this.abilityContext()
      const documentPicker = new picker.DocumentViewPicker(context)
      const uris = await documentPicker.select({
        maxSelectNumber: 50,
      })
      if (uris.length === 0) {
        this.statusText = '未选择文件'
        return
      }

      await this.sendUris(uris)
    } catch (err) {
      this.statusText = `发送失败：${JSON.stringify(err)}`
    }
  }

  private async sendUris(uris: Array<string>): Promise<void> {
    const device = this.selectedDevice
    if (!device) {
      this.statusText = '请等待发现并选择 Mac'
      return
    }

    const context = this.abilityContext()
    for (let index = 0; index < uris.length; index++) {
      try {
        const source = await this.archiveService.prepare(uris[index], context)
        await this.sendPreparedSource(source, device)
      } catch (err) {
        const failedId = `${Date.now()}-${Math.floor(Math.random() * 100000)}`
        this.runOnUi(() => {
          this.upsertCurrentTransfer({
            id: failedId,
            fileName: fileNameFromUri(uris[index]),
            peerName: device.deviceName,
            direction: '发送',
            progress: 0,
            detail: `准备失败：${JSON.stringify(err)}`,
            state: '失败',
            timeText: nowText(),
            startedAt: Date.now(),
            fileSize: 0,
            fileType: fileTypeLabel(fileNameFromUri(uris[index])),
            localPath: uris[index],
          })
          this.completeTransfer(failedId, false, `准备失败：${JSON.stringify(err)}`)
        })
      }
    }
  }

  private async sendPreparedSource(source: SendableSource, device: DeviceInfo): Promise<void> {
    const transferId = `${Date.now()}-${Math.floor(Math.random() * 100000)}`
    this.activeTransferDeviceIds.set(transferId, device.deviceId)
    this.runOnUi(() => {
      this.upsertCurrentTransfer({
        id: transferId,
        fileName: source.displayName,
        peerName: device.deviceName,
        direction: '发送',
        progress: 0,
        detail: source.isArchive ? '已压缩为 zip，准备发送' : '准备发送',
        state: '传输中',
        timeText: nowText(),
        startedAt: Date.now(),
        fileSize: source.fileSize,
        fileType: source.fileType,
        localPath: source.uri,
      })
    })

    try {
      this.progressValue = 0
      await this.transferService.sendFileToMac(source.uri, device.ip, device.port, {
        onStatus: (value: string) => {
          this.runOnUi(() => {
            this.statusText = value
          })
        },
        onProgress: (current: number, total: number) => {
          this.runOnUi(() => {
            this.progressValue = total > 0 ? Math.floor(current / total * 100) : 100
            this.updateCurrentTransfer(transferId, this.progressValue, this.progressDetail(transferId, current, total))
          })
        },
        onIncoming: async (_meta: FileMeta) => {
          return false
        },
      }, this.deviceId, this.localDeviceName(), source.displayName)
      this.runOnUi(() => {
        this.completeTransfer(transferId, true, '发送完成')
      })
    } catch (err) {
      this.runOnUi(() => {
        this.statusText = `发送失败：${JSON.stringify(err)}`
        this.completeTransfer(transferId, false, `发送失败：${JSON.stringify(err)}`)
      })
    } finally {
      this.cleanupPreparedSource(source)
    }
  }

  private handleDrop(event: DragEvent): void {
    try {
      const uris = this.urisFromDropEvent(event)
      if (uris.length === 0) {
        this.statusText = '拖拽内容没有可读取的文件地址'
        return
      }
      this.sendUris(uris)
    } catch (err) {
      this.statusText = `拖拽读取失败：${JSON.stringify(err)}`
    }
  }

  private urisFromDropEvent(event: DragEvent): Array<string> {
    try {
      const data = event.getData()
      const records = data.getRecords()
      const uris: Array<string> = []
      records.forEach((record: unifiedDataChannel.UnifiedRecord) => {
        const uri = this.uriFromRecord(record)
        if (uri.length > 0 && uris.indexOf(uri) < 0) {
          uris.push(uri)
        }
      })
      return uris
    } catch (_) {
      return []
    }
  }

  private uriFromRecord(record: unifiedDataChannel.UnifiedRecord): string {
    if (record instanceof unifiedDataChannel.Folder) {
      return (record as unifiedDataChannel.Folder).folderUri
    }
    if (record instanceof unifiedDataChannel.Image) {
      return (record as unifiedDataChannel.Image).imageUri
    }
    if (record instanceof unifiedDataChannel.Video) {
      return (record as unifiedDataChannel.Video).videoUri
    }
    if (record instanceof unifiedDataChannel.Audio) {
      return (record as unifiedDataChannel.Audio).audioUri
    }
    if (record instanceof unifiedDataChannel.File) {
      return (record as unifiedDataChannel.File).uri
    }

    try {
      const value = record.getValue()
      return typeof value === 'string' ? value : ''
    } catch (_) {
      return ''
    }
  }

  private upsertCurrentTransfer(item: TransferListItemOptions): void {
    const next = this.currentTransfers.filter((row: TransferListItem) => row.id !== item.id)
    next.unshift(new TransferListItem(item))
    this.currentTransfers = next
  }

  private updateCurrentTransfer(id: string, progress: number, detail: string): void {
    const matched = this.currentTransfers.filter((row: TransferListItem) => row.id === id)
    if (matched.length === 0) {
      return
    }
    matched[0].progress = progress
    matched[0].detail = detail
  }

  private completeTransfer(id: string, success: boolean, detail: string, localPath?: string): void {
    const matched = this.currentTransfers.filter((row: TransferListItem) => row.id === id)
    this.currentTransfers = this.currentTransfers.filter((row: TransferListItem) => row.id !== id)
    const historyDeviceId = this.activeTransferDeviceIds.get(id) ?? this.selectedDeviceId
    this.activeTransferDeviceIds.delete(id)
    if (matched.length === 0) {
      return
    }
    const source = matched[0]
    if (localPath && localPath.length > 0) {
      source.localPath = localPath
    }
    const item = source.copyWith(
      success ? 100 : source.progress,
      completionDetail(detail, source),
      success ? '已完成' : '失败',
      nowText()
    )
    this.appendHistory(item, historyDeviceId)
  }

  private appendHistory(item: TransferListItem, deviceId: string): void {
    if (deviceId.length === 0) {
      return
    }
    const existing = this.historyTransfersByDevice.get(deviceId) ?? []
    const next = existing.filter((row: TransferListItem) => {
      return !(row.fileName === item.fileName &&
        row.peerName === item.peerName &&
        row.direction === item.direction &&
        row.state === item.state &&
        row.timeText === item.timeText)
    })
    next.unshift(item.copyWith(item.progress, item.detail, item.state, item.timeText))
    const limited = next.slice(0, 30)
    this.historyTransfersByDevice.set(deviceId, limited)
    if (this.selectedDeviceId === deviceId) {
      this.historyTransfers = limited
    }
  }

  private refreshHistoryForSelectedDevice(): void {
    if (this.selectedDeviceId.length === 0) {
      this.historyTransfers = []
      return
    }
    this.historyTransfers = this.historyTransfersByDevice.get(this.selectedDeviceId) ?? []
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
    const currentDeviceId = this.selectedDeviceId
    if (currentDeviceId.length > 0) {
      const currentRows = this.historyTransfersByDevice.get(currentDeviceId) ?? []
      const updatedCurrent = this.updatedHistoryRows(currentRows, id, detailPrefix)
      if (updatedCurrent.length > 0) {
        this.historyTransfersByDevice.set(currentDeviceId, updatedCurrent)
        this.historyTransfers = updatedCurrent
        return
      }
    }

    this.historyTransfersByDevice.forEach((rows: Array<TransferListItem>, deviceId: string) => {
      const updated = this.updatedHistoryRows(rows, id, detailPrefix)
      if (updated.length > 0) {
        this.historyTransfersByDevice.set(deviceId, updated)
        if (this.selectedDeviceId === deviceId) {
          this.historyTransfers = updated
        }
      }
    })
  }

  private updatedHistoryRows(rows: Array<TransferListItem>, id: string, detailPrefix: string): Array<TransferListItem> {
    let hasMatch = false
    const updated = rows.map((row: TransferListItem) => {
      if (row.id !== id) {
        return row
      }
      hasMatch = true
      const next = row.copyWith(row.progress, completionDetail(detailPrefix, row), row.state, row.timeText)
      return next
    })
    return hasMatch ? updated : []
  }

  private cleanupPreparedSource(source: SendableSource): void {
    if (!source.isArchive) {
      return
    }
    try {
      fs.unlinkSync(source.uri)
    } catch (_) {
    }
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
