import { common } from '@kit.AbilityKit'
import { fileNameFromUri, fileTypeLabel } from '../common/Formatters'
import { DeviceInfo, FileMeta, PairingRequest } from '../common/Protocol'
import { TransferListItemOptions, TransferState } from '../models/TransferListItem'
import { ArchiveService, SendableSource } from './ArchiveService'
import { TcpTransferService, TransferCallbacks } from './TcpTransferService'
import { errorText } from '../common/ErrorText'

export interface OutgoingIdentity {
  deviceId: string
  deviceName: string
  fingerprint: string
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

/** 每个源文件只准备一次，并在多个接收端间复用；Pad 端并发上限为两个。 */
export class OutgoingTransferCoordinator {
  private transferService: TcpTransferService
  private archiveService: ArchiveService

  constructor(transferService: TcpTransferService, archiveService: ArchiveService) {
    this.transferService = transferService
    this.archiveService = archiveService
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
      let preserve = false
      for (let index = 0; index < jobs.length; index += 2) {
        const results = await Promise.all(jobs.slice(index, index + 2).map((job) => job()))
        preserve = preserve || results.some((value: boolean) => value)
      }
      if (!preserve) this.cleanup(source)
    }
  }

  async sendPrepared(source: SendableSource, device: DeviceInfo, identity: OutgoingIdentity,
    callbacks: OutgoingTransferCallbacks, transferId: string, groupId?: string,
    cleanupSource: boolean = true): Promise<boolean> {
    callbacks.onBegin({
      id: transferId, groupId: groupId ?? transferId, fileName: source.displayName, peerName: device.deviceName,
      direction: '发送', progress: 0, detail: source.isArchive ? '已压缩为 zip，准备发送' : '准备发送',
      state: TransferState.Active, timeText: '', startedAt: Date.now(), fileSize: source.fileSize,
      fileType: source.fileType, localPath: source.originalUri, stagingPath: source.uri,
      sourceSize: source.sourceSize, sourceFileCount: source.sourceFileCount,
    }, device.deviceId)

    let preserve = false
    const transferCallbacks: TransferCallbacks = {
      onStatus: callbacks.onStatus,
      onProgress: (current: number, total: number) => callbacks.onProgress(transferId, current, total),
      onIncoming: async (_meta: FileMeta) => false,
      onPairing: async (_request: PairingRequest) => false,
      onTransferActivity: callbacks.onActivity,
    }
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
      })
      callbacks.onComplete(transferId)
    } catch (err) {
      const detail = errorText(err)
      const paused = detail.indexOf('receiver_paused') >= 0
      const permanent = !paused && (detail.indexOf('接收方拒绝') >= 0 || detail.indexOf('hash_mismatch') >= 0 ||
        detail.indexOf('接收方报告失败') >= 0 || detail.indexOf('insufficient_space') >= 0 ||
        detail.indexOf('13900002') >= 0 || detail.indexOf('Persistent staging source is missing') >= 0)
      if (permanent) {
        // 保留私有源文件供用户主动重试，暂存维护服务会在七天后清理。
        preserve = true
        callbacks.onPermanentFailure(transferId, detail)
      }
      else {
        preserve = true
        callbacks.onWaiting(transferId, detail)
      }
    } finally {
      if (cleanupSource && !preserve && !callbacks.isSourceReferenced(source.uri)) this.cleanup(source)
    }
    return preserve
  }

  private failureOptions(uri: string, device: DeviceInfo, id: string, groupId: string,
    detail: string): TransferListItemOptions {
    const name = fileNameFromUri(uri)
    return { id, groupId, fileName: name, peerName: device.deviceName, direction: '发送', progress: 0, detail,
      state: TransferState.Failed, timeText: '', startedAt: Date.now(), fileSize: 0, fileType: fileTypeLabel(name), localPath: uri }
  }

  private cleanup(source: SendableSource): void {
    if (!source.stagingOwned) return
    try { this.archiveService.removePrepared(source) } catch (_) {}
  }
}
