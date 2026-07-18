import { common } from '@kit.AbilityKit'
import { fileNameFromUri, fileTypeLabel } from '../common/Formatters'
import { DeviceInfo, FileMeta, PairingRequest } from '../common/Protocol'
import { TransferDirection, TransferListItemOptions, TransferState } from '../models/TransferListItem'
import { ArchiveService, SendableSource } from './ArchiveService'
import { TcpTransferService, TransferCallbacks } from './TcpTransferService'
import { errorText } from '../common/ErrorText'
import { AsyncConcurrencyGate } from './AsyncConcurrencyGate'

export interface OutgoingIdentity {
  deviceId: string
  deviceName: string
  fingerprint: string
  sharedSecrets: Map<string, string>
}

export interface OutgoingTransferCallbacks {
  onStatus: (value: string) => void
  onBegin: (options: TransferListItemOptions, deviceId: string) => void
  onProgress: (transferId: string, current: number, total: number) => void
  onComplete: (transferId: string) => void
  onPermanentFailure: (transferId: string, detail: string) => void
  onWaiting: (transferId: string, detail: string) => void
  onActivity: (active: boolean) => void
  onPreparationFailure: (options: TransferListItemOptions, deviceId: string, detail: string) => void
  isSourceReferenced: (path: string) => boolean
}

/** 让尚未取得并发名额的任务也能立即响应暂停和取消，而不是排队结束后意外发送。 */
class QueuedTransferControl {
  private paused: boolean = false
  private cancelled: boolean = false
  private waiters: Array<() => void> = []

  pause(): void { if (!this.cancelled) this.paused = true }
  resume(): void { this.paused = false; this.releaseWaiters() }
  cancel(): void { this.cancelled = true; this.paused = false; this.releaseWaiters() }
  isCancelled(): boolean { return this.cancelled }

  async checkpoint(): Promise<void> {
    if (this.cancelled) throw new Error('transfer_cancelled')
    if (this.paused) {
      await new Promise<void>((resolve) => this.waiters.push(resolve))
    }
    if (this.cancelled) throw new Error('transfer_cancelled')
  }

  private releaseWaiters(): void {
    const waiters = this.waiters
    this.waiters = []
    waiters.forEach((resolve: () => void) => resolve())
  }
}

/** 每个源文件只准备一次，并在多个接收端间复用；Pad 端并发上限为两个。 */
export class OutgoingTransferCoordinator {
  private transferService: TcpTransferService
  private archiveService: ArchiveService
  private sendGate: AsyncConcurrencyGate = new AsyncConcurrencyGate(2)
  private queuedControls: Map<string, QueuedTransferControl> = new Map()

  constructor(transferService: TcpTransferService, archiveService: ArchiveService) {
    this.transferService = transferService
    this.archiveService = archiveService
  }

  pause(transferId: string): void {
    this.queuedControls.get(transferId)?.pause()
    this.transferService.pauseTransfer(transferId)
  }

  resume(transferId: string): void {
    this.queuedControls.get(transferId)?.resume()
    this.transferService.resumeTransfer(transferId)
  }

  cancel(transferId: string): void {
    this.queuedControls.get(transferId)?.cancel()
    this.transferService.cancelTransfer(transferId)
  }

  cancelAll(): void {
    this.queuedControls.forEach((control: QueuedTransferControl, id: string) => {
      control.cancel()
      this.transferService.cancelTransfer(id)
    })
  }

  async waitForIdle(timeoutMs: number = 3000): Promise<boolean> {
    const deadline = Date.now() + timeoutMs
    while (Date.now() < deadline) {
      if (this.queuedControls.size === 0) return true
      await new Promise<void>((resolve) => setTimeout(resolve, 50))
    }
    return this.queuedControls.size === 0
  }

  async sendUris(uris: Array<string>, targets: Array<DeviceInfo>, context: common.UIAbilityContext,
    identity: OutgoingIdentity, callbacks: OutgoingTransferCallbacks): Promise<void> {
    const groupId = `${Date.now()}-${Math.floor(Math.random() * 100000)}`
    for (let fileIndex = 0; fileIndex < uris.length; fileIndex += 1) {
      const uri = uris[fileIndex]
      let source: SendableSource
      try {
        source = await this.archiveService.prepare(uri, context, `${groupId}-${fileIndex}-shared`)
      } catch (err) {
        targets.forEach((device: DeviceInfo, deviceIndex: number) => {
          const id = `${groupId}-${fileIndex}-${deviceIndex}`
          const detail = `准备失败：${errorText(err)}`
          callbacks.onPreparationFailure(this.failureOptions(uri, device, id, groupId, detail), device.deviceId, detail)
        })
        continue
      }

      const jobs = targets.map((device: DeviceInfo, deviceIndex: number) => async (): Promise<boolean> => {
        return await this.sendPrepared(source, device, identity, callbacks,
          `${groupId}-${fileIndex}-${deviceIndex}`, groupId, false)
      })
      const results = await Promise.all(jobs.map((job) => job()))
      const preserve = results.some((value: boolean) => value)
      if (!preserve) this.cleanup(source)
    }
  }

  async sendPrepared(source: SendableSource, device: DeviceInfo, identity: OutgoingIdentity,
    callbacks: OutgoingTransferCallbacks, transferId: string, groupId?: string,
    cleanupSource: boolean = true): Promise<boolean> {
    const queueControl = new QueuedTransferControl()
    this.queuedControls.set(transferId, queueControl)
    callbacks.onBegin({
      id: transferId, groupId: groupId ?? transferId, fileName: source.displayName, peerName: device.deviceName,
      direction: TransferDirection.Sending, progress: 0,
      detail: source.isArchive ? '已压缩为 zip，等待发送' : '排队等待传输',
      state: TransferState.Preparing, timeText: '', startedAt: Date.now(), fileSize: source.fileSize,
      fileType: source.fileType, localPath: source.originalUri, stagingPath: source.uri,
      sourceSize: source.sourceSize, sourceFileCount: source.sourceFileCount,
    }, device.deviceId)

    try {
      await queueControl.checkpoint()
      return await this.sendGate.run(async (): Promise<boolean> => {
        let preserve = false
        const transferCallbacks: TransferCallbacks = {
          onStatus: callbacks.onStatus,
          onProgress: (current: number, total: number) => callbacks.onProgress(transferId, current, total),
          onIncoming: async (_meta: FileMeta) => false,
          onPairingCode: async (_request: PairingRequest) => undefined,
          onPairingEstablished: async (_request: PairingRequest, _sharedSecret: string) => {},
          onTransferActivity: callbacks.onActivity,
        }
        await queueControl.checkpoint()
        try {
          await this.transferService.sendFileToMac({
            uri: source.uri,
            host: device.ip,
            port: device.port,
            callbacks: transferCallbacks,
            senderDeviceId: identity.deviceId,
            senderName: identity.deviceName,
            displayName: source.displayName,
            transferId,
            sourceKind: source.isArchive ? 'folder' : 'file',
            originalSourceName: source.displayName,
            sourceSize: source.sourceSize,
            sourceFileCount: source.sourceFileCount,
            senderFingerprint: identity.fingerprint,
            sharedSecret: identity.sharedSecrets.get(device.deviceId),
          })
          callbacks.onComplete(transferId)
        } catch (err) {
          if (queueControl.isCancelled()) return true
          const detail = errorText(err)
          const paused = detail.indexOf('receiver_paused') >= 0
          const permanent = !paused && (detail.indexOf('接收方拒绝') >= 0 || detail.indexOf('hash_mismatch') >= 0 ||
            detail.indexOf('接收方报告失败') >= 0 || detail.indexOf('insufficient_space') >= 0 ||
            detail.indexOf('13900002') >= 0 || detail.indexOf('SRC-MISSING-001') >= 0)
          if (permanent) {
            // 保留私有源文件供用户主动重试，暂存维护服务会在七天后清理。
            preserve = true
            callbacks.onPermanentFailure(transferId, detail)
          } else {
            preserve = true
            callbacks.onWaiting(transferId, detail)
          }
        } finally {
          if (cleanupSource && !preserve && !callbacks.isSourceReferenced(source.uri)) this.cleanup(source)
        }
        return preserve
      })
    } catch (err) {
      if (queueControl.isCancelled()) return true
      throw new Error(errorText(err))
    } finally {
      if (this.queuedControls.get(transferId) === queueControl) this.queuedControls.delete(transferId)
    }
  }

  private failureOptions(uri: string, device: DeviceInfo, id: string, groupId: string,
    detail: string): TransferListItemOptions {
    const name = fileNameFromUri(uri)
    return { id, groupId, fileName: name, peerName: device.deviceName,
      direction: TransferDirection.Sending, progress: 0, detail,
      state: TransferState.Failed, timeText: '', startedAt: Date.now(), fileSize: 0, fileType: fileTypeLabel(name), localPath: uri }
  }

  private cleanup(source: SendableSource): void {
    if (!source.stagingOwned) return
    try { this.archiveService.removePrepared(source) } catch (_) {}
  }
}
