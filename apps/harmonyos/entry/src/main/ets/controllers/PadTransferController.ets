import { common } from '@kit.AbilityKit'
import { picker } from '@kit.CoreFileKit'
import { DeviceInfo, FileMeta } from '../common/Protocol'
import { formatBytes, nowText } from '../common/Formatters'
import { errorText } from '../common/ErrorText'
import { TransferListItem, TransferListItemOptions, TransferState } from '../models/TransferListItem'
import { ArchiveService, SendableSource } from '../services/ArchiveService'
import { DropUriService } from '../services/DropUriService'
import { OutgoingTransferCallbacks, OutgoingTransferCoordinator } from '../services/OutgoingTransferCoordinator'
import { StagingStorageService } from '../services/StagingStorageService'
import { TcpTransferService } from '../services/TcpTransferService'
import { TransferStateService } from '../services/TransferStateService'
import { TransferStore } from '../persistence/TransferStore'

/**
 * ArkUI 页面实现的最小桥接接口。控制器负责传输决策，页面仍是响应式界面状态的唯一来源。
 */
export interface PadTransferHost {
  statusText: string
  currentTransfers: Array<TransferListItem>
  historyTransfers: Array<TransferListItem>
  selectedDeviceIds: Array<string>
  selectedDeviceId: string
  deviceId: string
  identityFingerprint: string
  activeTransferDeviceIds: Map<string, string>
  connectedDevices: Array<DeviceInfo>
  selectedDevice: DeviceInfo | undefined
  freshDevices: Array<DeviceInfo>

  abilityContext(): common.UIAbilityContext
  localDeviceName(): string
  runOnUi(task: () => void): void
  persistTransferState(immediate?: boolean): void
  updateBackgroundTransferActivity(active: boolean): void
  resumeWaitingTransfers(device: DeviceInfo): void
  confirmCancellation(title: string, message: string): Promise<number>
  showToast(message: string): void
}

/** 协调文件选择、多目标发送与可持久化的任务控制。 */
export class PadTransferController {
  private host: PadTransferHost
  private transferService: TcpTransferService
  private transferStore: TransferStore
  private archiveService: ArchiveService
  private stagingStorageService: StagingStorageService
  private dropUriService: DropUriService
  private transferStateService: TransferStateService
  private outgoingCoordinator: OutgoingTransferCoordinator
  private automaticResumeTimers: Map<string, number> = new Map()

  constructor(
    host: PadTransferHost,
    transferService: TcpTransferService,
    transferStore: TransferStore,
    archiveService: ArchiveService,
    stagingStorageService: StagingStorageService,
    dropUriService: DropUriService,
    transferStateService: TransferStateService,
    outgoingCoordinator: OutgoingTransferCoordinator,
  ) {
    this.host = host
    this.transferService = transferService
    this.transferStore = transferStore
    this.archiveService = archiveService
    this.stagingStorageService = stagingStorageService
    this.dropUriService = dropUriService
    this.transferStateService = transferStateService
    this.outgoingCoordinator = outgoingCoordinator
  }

  async selectAndSendFile(): Promise<void> {
    if (this.host.connectedDevices.length === 0) {
      this.host.statusText = '请等待发现并选择 Mac'
      return
    }
    try {
      const documentPicker = new picker.DocumentViewPicker(this.host.abilityContext())
      const options: picker.DocumentSelectOptions = { maxSelectNumber: 50 }
      if (canIUse('SystemCapability.FileManagement.UserFileService.FolderSelection')) {
        options.selectMode = picker.DocumentSelectMode.MIXED
      }
      const uris = await documentPicker.select(options)
      if (uris.length === 0) {
        this.host.statusText = '未选择文件'
        return
      }
      await this.sendUris(uris)
    } catch (err) {
      this.host.statusText = `发送失败：${errorText(err)}`
      this.host.showToast('无法读取所选文件，请重新选择')
    }
  }

  async sendUris(uris: Array<string>): Promise<void> {
    const selectedTargets = this.host.connectedDevices.filter((device: DeviceInfo) =>
      this.host.selectedDeviceIds.indexOf(device.deviceId) >= 0)
    const targets = selectedTargets.length > 0 ? selectedTargets :
      (this.host.connectedDevices.length === 1 ? this.host.connectedDevices : [])
    if (targets.length === 0) {
      this.host.statusText = this.host.connectedDevices.length > 1 ? '请至少选择一台接收设备' : '请等待发现并选择 Mac'
      return
    }
    await this.outgoingCoordinator.sendUris(uris, targets, this.host.abilityContext(), {
      deviceId: this.host.deviceId,
      deviceName: this.host.localDeviceName(),
      fingerprint: this.host.identityFingerprint,
    }, this.outgoingCallbacks())
  }

  transferTargetLabel(): string {
    if (this.host.selectedDeviceIds.length > 1) return `${this.host.selectedDeviceIds.length} 台设备`
    if (this.host.selectedDevice) return this.host.selectedDevice.deviceName
    if (this.host.connectedDevices.length === 1) return this.host.connectedDevices[0].deviceName
    if (this.host.connectedDevices.length > 1) return `${this.host.connectedDevices.length} 台设备`
    return ''
  }

  async sendPreparedSource(source: SendableSource, device: DeviceInfo, reuseTransferId?: string,
    groupId?: string, cleanupSource: boolean = true): Promise<boolean> {
    const transferId = reuseTransferId ?? `${Date.now()}-${Math.floor(Math.random() * 100000)}`
    return await this.outgoingCoordinator.sendPrepared(source, device, {
      deviceId: this.host.deviceId,
      deviceName: this.host.localDeviceName(),
      fingerprint: this.host.identityFingerprint,
    }, this.outgoingCallbacks(), transferId, groupId, cleanupSource)
  }

  handleDrop(event: DragEvent): void {
    try {
      const uris = this.dropUriService.extract(event)
      if (uris.length === 0) {
        this.host.statusText = '拖拽内容没有可读取的文件地址'
        return
      }
      this.sendUris(uris)
    } catch (err) {
      this.host.statusText = `拖拽读取失败：${errorText(err)}`
    }
  }

  upsertCurrentTransfer(item: TransferListItemOptions): void {
    this.host.currentTransfers = this.transferStateService.upsert(this.host.currentTransfers, item,
      this.host.activeTransferDeviceIds.get(item.id) ?? this.host.selectedDeviceId)
    this.host.persistTransferState(true)
  }

  updateCurrentTransfer(id: string, progress: number, detail: string): void {
    this.transferStateService.updateProgress(this.host.currentTransfers, id, progress, detail)
    this.host.persistTransferState()
  }

  toggleTransferPause(item: TransferListItem): void {
    if (item.direction === '接收') {
      if (item.state === TransferState.Paused) {
        this.transferService.resumeTransfer(item.id)
        this.markCurrentTransferState(item.id, TransferState.Waiting, '接收已恢复，等待发送端重连')
      } else {
        this.transferService.pauseTransfer(item.id)
        this.markCurrentTransferState(item.id, TransferState.Paused, '接收已暂停，分片已保留')
      }
      return
    }
    if (item.state === TransferState.Waiting) {
      const device = this.matchingDevice(item)
      if (!device) {
        this.host.statusText = `请先重新连接 ${item.peerName}`
        return
      }
      this.host.resumeWaitingTransfers(device)
      return
    }
    if (item.state === TransferState.Paused) {
      this.outgoingCoordinator.resume(item.id)
      this.markCurrentTransferState(item.id, TransferState.Active, '正在继续传输')
    } else {
      this.outgoingCoordinator.pause(item.id)
      this.markCurrentTransferState(item.id, TransferState.Paused, '已暂停网络发送')
    }
  }

  toggleTransferGroup(item: TransferListItem): void {
    const rows = this.host.currentTransfers.filter((row: TransferListItem) => row.groupId === item.groupId)
    const shouldPause = rows.some((row: TransferListItem) => row.state !== TransferState.Paused &&
      row.state !== TransferState.Waiting)
    rows.forEach((row: TransferListItem) => {
      if (shouldPause && row.state !== TransferState.Paused && row.state !== TransferState.Waiting) {
        this.toggleTransferPause(row)
      }
      if (!shouldPause && (row.state === TransferState.Paused || row.state === TransferState.Waiting)) {
        this.toggleTransferPause(row)
      }
    })
  }

  cancelTransfer(item: TransferListItem): void {
    this.clearAutomaticResume(item.id)
    if (item.direction === '发送') this.outgoingCoordinator.cancel(item.id)
    else this.transferService.cancelTransfer(item.id)
    this.host.activeTransferDeviceIds.delete(item.id)
    this.host.currentTransfers = this.host.currentTransfers.filter((row: TransferListItem) => row.id !== item.id)
    this.appendHistory(item.copyWith(item.progress, '用户取消', TransferState.Cancelled, nowText()),
      item.deviceId.length > 0 ? item.deviceId : this.host.selectedDeviceId)
  }

  confirmCancelTransfer(item: TransferListItem): void {
    this.host.confirmCancellation('取消传输？', '可以保留私有分片以便稍后恢复，或同时删除该任务的可恢复数据。')
      .then((policy: number) => {
        if (policy !== 1 && policy !== 2) return
        this.cancelTransfer(item)
        if (policy === 2) this.deleteRecoverableArtifact(item)
      })
  }

  confirmCancelTransferGroup(item: TransferListItem): void {
    const rows = this.host.currentTransfers.filter((row: TransferListItem) => row.groupId === item.groupId)
    this.host.confirmCancellation(`取消整组 ${rows.length} 个任务？`,
      '每台设备的任务会分别取消，可以保留或删除共享的可恢复数据。').then((policy: number) => {
      if (policy !== 1 && policy !== 2) return
      rows.forEach((row: TransferListItem) => {
        this.cancelTransfer(row)
        if (policy === 2) this.deleteRecoverableArtifact(row)
      })
    })
  }

  deleteRecoverableArtifact(item: TransferListItem): void {
    const stagingRoot = `${this.host.abilityContext().filesDir}/HMTrans/Staging`
    this.stagingStorageService.removeRecursively(`${stagingRoot}/${item.id}.part`)
    this.stagingStorageService.removeRecursively(`${stagingRoot}/${item.id}.meta.json`)
    const source = item.stagingPath
    if (source && !this.host.currentTransfers.some((row: TransferListItem) => row.stagingPath === source)) {
      this.stagingStorageService.removeRecursively(source)
    }
  }

  markCurrentTransferState(id: string, state: string, detail: string): void {
    this.transferStateService.mark(this.host.currentTransfers, id, state, detail)
    this.host.persistTransferState(true)
  }

  scheduleAutomaticResume(id: string): void {
    this.clearAutomaticResume(id)
    const timer = setTimeout(() => {
      this.automaticResumeTimers.delete(id)
      const waiting = this.host.currentTransfers.some((item: TransferListItem) =>
        item.id === id && item.state === TransferState.Waiting)
      const item = this.host.currentTransfers.find((row: TransferListItem) => row.id === id)
      const device = item ? this.matchingDevice(item) : undefined
      if (waiting && device && !this.host.activeTransferDeviceIds.has(id)) {
        this.host.resumeWaitingTransfers(device)
      }
    }, 2000)
    this.automaticResumeTimers.set(id, timer)
  }

  /** 页面退出时撤销所有延迟恢复，避免销毁后的回调继续访问页面状态。 */
  clearLifecycleTimers(): void {
    this.automaticResumeTimers.forEach((timer: number) => clearTimeout(timer))
    this.automaticResumeTimers.clear()
  }

  completeTransfer(id: string, success: boolean, detail: string, localPath?: string): void {
    this.clearAutomaticResume(id)
    const historyDeviceId = this.host.activeTransferDeviceIds.get(id) ?? this.host.selectedDeviceId
    this.host.activeTransferDeviceIds.delete(id)
    const result = this.transferStateService.complete(this.host.currentTransfers, id, success, detail, localPath,
      historyDeviceId)
    this.host.currentTransfers = result.current
    if (result.historyItem) this.appendHistory(result.historyItem, historyDeviceId)
  }

  appendHistory(item: TransferListItem, deviceId: string): void {
    if (deviceId.length === 0) return
    this.host.historyTransfers = this.transferStateService.appendHistory(this.host.historyTransfers, item, deviceId)
    this.host.persistTransferState(true)
  }

  historyDeviceIdForIncoming(meta: FileMeta): string {
    if (meta.senderDeviceId && meta.senderDeviceId.length > 0) return meta.senderDeviceId
    return this.host.selectedDeviceId
  }

  async markReceivedFilePublished(transferId: string, _fileName: string, _path: string): Promise<void> {
    this.updateHistoryDetail(transferId, '已保存到下载目录 HMTrans')
  }

  updateHistoryDetail(id: string, detailPrefix: string): void {
    this.host.historyTransfers = this.transferStateService.updateHistory(this.host.historyTransfers, id, detailPrefix)
    this.host.persistTransferState(true)
  }

  progressDetail(id: string, current: number, total: number): string {
    if (total <= 0) return TransferState.Active
    const matched = this.host.currentTransfers.filter((row: TransferListItem) => row.id === id)
    const startedAt = matched.length > 0 ? matched[0].startedAt : Date.now()
    const speed = current / Math.max((Date.now() - startedAt) / 1000, 0.15)
    return `${formatBytes(current)} / ${formatBytes(total)} · ${formatBytes(speed)}/s`
  }

  private outgoingCallbacks(): OutgoingTransferCallbacks {
    return {
      // 发送可在应用切到后台后继续。任务状态必须先写回模型并持久化，不能因为页面暂时
      // 不可见而丢掉最终回执；ArkTS 的 Promise 与 socket 回调均回到当前 JS 运行时。
      onStatus: (value: string) => { this.host.statusText = value },
      onBegin: (options: TransferListItemOptions, deviceId: string) => {
        this.host.activeTransferDeviceIds.set(options.id, deviceId)
        if (this.host.currentTransfers.some((item: TransferListItem) => item.id === options.id)) {
          this.markCurrentTransferState(options.id, TransferState.Preparing, '正在协商断点')
        } else {
          options.timeText = nowText()
          this.upsertCurrentTransfer(options)
        }
      },
      onProgress: (id: string, current: number, total: number) => {
        const progress = total > 0 ? Math.floor(current / total * 100) : 100
        this.updateCurrentTransfer(id, progress, this.progressDetail(id, current, total))
      },
      onComplete: (id: string) => this.completeTransfer(id, true, '发送完成'),
      onPermanentFailure: (id: string, detail: string) => {
        this.host.statusText = `发送失败：${detail}`
        this.transferStore.recordDiagnostic('TRN-SEND-001', detail, id).catch(() => {})
        this.completeTransfer(id, false, `发送失败：${detail}`)
      },
      onWaiting: (id: string, _detail: string) => {
        this.host.activeTransferDeviceIds.delete(id)
        this.markCurrentTransferState(id, TransferState.Waiting, '连接中断，已保存断点')
        this.scheduleAutomaticResume(id)
      },
      onActivity: (active: boolean) => this.host.updateBackgroundTransferActivity(active),
      onPreparationFailure: (options: TransferListItemOptions, deviceId: string, detail: string) =>
        {
          this.host.activeTransferDeviceIds.set(options.id, deviceId)
          options.timeText = nowText()
          this.upsertCurrentTransfer(options)
          this.completeTransfer(options.id, false, detail)
        },
      isSourceReferenced: (path: string) => this.host.currentTransfers.some((item: TransferListItem) =>
        item.stagingPath === path),
    }
  }

  private clearAutomaticResume(id: string): void {
    const timer = this.automaticResumeTimers.get(id)
    if (timer !== undefined) clearTimeout(timer)
    this.automaticResumeTimers.delete(id)
  }

  /** 恢复任务必须按稳定设备 ID 路由；旧记录仅在设备名称唯一时兼容匹配。 */
  private matchingDevice(item: TransferListItem): DeviceInfo | undefined {
    if (item.deviceId.length > 0) {
      return this.host.freshDevices.find((device: DeviceInfo) => device.deviceId === item.deviceId)
    }
    const legacyMatches = this.host.freshDevices.filter((device: DeviceInfo) => device.deviceName === item.peerName)
    return legacyMatches.length === 1 ? legacyMatches[0] : undefined
  }
}
