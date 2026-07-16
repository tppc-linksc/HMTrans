import { common } from '@kit.AbilityKit'
import { settings } from '@kit.BasicServicesKit'
import { wifiManager } from '@kit.ConnectivityKit'
import {
  DeviceInfo,
  FileMeta,
  PairingRequest,
  UnpairRequest,
  createPairingRequest,
  createUnpairRequest,
  wifiIpAddress,
} from '../common/Protocol'
import { fileTypeLabel, formatBytes, nowText } from '../common/Formatters'
import { errorText } from '../common/ErrorText'
import { TransferListItem, TransferState } from '../models/TransferListItem'
import { SendableSource } from '../services/ArchiveService'
import { DiscoveryService } from '../services/DiscoveryService'
import { PadNetworkHost } from './PadNetworkHost'

const DEVICE_TTL_MS: number = 12000
const DEVICE_PRUNE_INTERVAL_MS: number = 4000

/** 在页面之外管理接收、发现、在线状态与配对决策。 */
export class PadNetworkController {
  private host: PadNetworkHost

  constructor(host: PadNetworkHost) {
    this.host = host
  }

  beginIncomingTransfer(meta: FileMeta): void {
    const historyDeviceId = this.host.historyDeviceIdForIncoming(meta)
    if (historyDeviceId.length > 0) {
      this.host.activeTransferDeviceIds.set(meta.transferId, historyDeviceId)
    }
    const existing = this.host.currentTransfers.filter((row: TransferListItem) => row.id === meta.transferId)
    if (existing.length > 0) {
      return
    }
    const sourceSummary = meta.sourceKind === 'folder' ?
      `${meta.sourceFileCount ?? 0} 个文件 · 原始 ${formatBytes(meta.sourceSize ?? meta.fileSize)}` :
      formatBytes(meta.sourceSize ?? meta.fileSize)
    this.host.upsertCurrentTransfer({
      id: meta.transferId,
      fileName: meta.fileName,
      peerName: meta.senderName ?? meta.senderPlatform ?? 'Mac',
      direction: '接收',
      progress: 0,
      detail: `等待接收 · ${sourceSummary} · 载荷 ${formatBytes(meta.fileSize)}`,
      state: TransferState.Active,
      timeText: nowText(),
      startedAt: Date.now(),
      fileSize: meta.fileSize,
      fileType: fileTypeLabel(meta.fileName),
      sourceSize: meta.sourceSize ?? meta.fileSize,
      sourceFileCount: meta.sourceFileCount ?? 1,
      deviceId: historyDeviceId,
    })
  }

  // MARK: 接收与发现回调

  showIncomingPrompt(meta: FileMeta): Promise<boolean> {
    const sender = meta.senderName ?? meta.senderPlatform ?? '未知设备'
    return this.host.confirmReceive(sender, meta.fileName, formatBytes(meta.fileSize))
  }

  async ensureReceiverAndDiscovery(): Promise<void> {
    const context = this.host.abilityContext()
    if (this.host.receiverEnabled) {
      await this.startReceiver(context)
    } else {
      this.host.receiverReady = false
      await this.host.transferService.stopReceive()
    }
    if (this.host.discoveryEnabled) {
      await this.restartDiscovery()
    } else {
      await this.stopDiscovery()
    }
  }

  async startReceiver(context: common.UIAbilityContext): Promise<boolean> {
    try {
      await this.host.transferService.startReceiver(context, this.host.localTcpPort, {
        onStatus: (value: string) => {
          this.host.runOnUi(() => {
            this.host.statusText = value
            if (value.indexOf('接收服务错误') >= 0) {
              this.host.receiverReady = false
            }
          })
        },
        onProgress: (current: number, total: number, meta?: FileMeta) => {
          this.host.runOnUi(() => {
            const progressValue = total > 0 ? Math.floor(current / total * 100) : 100
            if (meta) {
              this.beginIncomingTransfer(meta)
              this.host.updateCurrentTransfer(meta.transferId, progressValue, this.host.progressDetail(meta.transferId, current, total))
            }
          })
        },
        onReceived: (meta: FileMeta, path: string) => {
          this.host.runOnUi(() => {
            this.host.completeTransfer(meta.transferId, true, `已保存到 ${path}`, path)
          })
          this.host.markReceivedFilePublished(meta.transferId, meta.fileName, path).catch((err: Error) => {
            this.host.runOnUi(() => {
              this.host.updateHistoryDetail(meta.transferId, `文件打开索引更新失败：${errorText(err)}`)
            })
          })
        },
        onFailed: (meta: FileMeta, reason: string) => {
          this.host.runOnUi(() => {
            this.host.transferStore.recordDiagnostic(this.errorCodeForReason(reason), reason, meta.transferId).catch(() => {})
            this.host.completeTransfer(meta.transferId, false, this.userMessageForReason(reason))
          })
        },
        onInterrupted: (meta: FileMeta, reason: string) => {
          this.host.runOnUi(() => {
            this.host.transferStore.recordDiagnostic('TRN-RECV-INT', reason, meta.transferId).catch(() => {})
            this.host.markCurrentTransferState(meta.transferId, TransferState.Waiting, '连接中断，已保存断点')
          })
        },
        onTransferActivity: (active: boolean) => {
          this.host.updateBackgroundTransferActivity(active)
        },
        onIncoming: async (meta: FileMeta) => {
          if (this.host.identityMatches(meta.senderDeviceId, meta.senderFingerprint) && this.host.autoReceiveTrustedEnabled) {
            this.host.runOnUi(() => {
              this.beginIncomingTransfer(meta)
              this.host.statusText = `自动接收：${meta.fileName}`
            })
            return true
          }
          if (this.host.identityMatches(meta.senderDeviceId, meta.senderFingerprint)) {
            return await this.showIncomingPrompt(meta)
          }
          this.host.runOnUi(() => {
            this.host.statusText = '已拒绝未配对设备的传输，请先输入六位配对码'
          })
          return false
        },
        onPairing: async (request: PairingRequest) => {
          const expected = this.host.pairingCode.replace(/\D/g, '')
          const accepted = this.host.pairingSeconds > 0 &&
            request.code.replace(/\D/g, '') === expected &&
            request.requesterFingerprint !== undefined && request.requesterFingerprint.length > 0
          if (accepted) {
            await this.host.trustDevice(request.requesterDeviceId, request.requesterFingerprint)
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
            this.host.deviceLastSeenAt.set(pairedDevice.deviceId, Date.now())
            this.host.nearbyDevices = this.host.nearbyDevices
              .filter((item: DeviceInfo) => item.deviceId !== pairedDevice.deviceId)
              .concat([pairedDevice])
            await this.host.rememberDevice(pairedDevice)
            this.host.runOnUi(() => {
              this.selectDevice(pairedDevice)
              this.host.statusText = `已与 ${request.requesterName} 完成配对，正在确认连接`
            })
          }
          return accepted
        },
        onUnpair: async (request: UnpairRequest) => {
          const accepted = request.targetDeviceId === this.host.deviceId &&
            this.host.identityMatches(request.requesterDeviceId, request.requesterFingerprint)
          if (!accepted) return false
          const device = this.host.nearbyDevices.find((row: DeviceInfo) =>
            row.deviceId === request.requesterDeviceId)
          await this.host.forgetTrustedDevice(
            request.requesterDeviceId,
            `${device?.deviceName ?? '对方设备'} 已解除配对`,
          )
          return true
        },
      }, this.host.receiveDirectory)
      this.host.receiverReady = true
      this.host.statusText = '自动发现和接收服务已开启'
      return true
    } catch (err) {
      this.host.receiverReady = false
      this.host.transferStore.recordDiagnostic('TRN-RECV-001', errorText(err)).catch(() => {})
      this.host.statusText = `接收服务启动失败，可能端口被旧版本占用：${errorText(err)}`
      return false
    }
  }

  errorCodeForReason(reason: string): string {
    if (reason.indexOf('insufficient_space') >= 0) return 'STO-SPACE-001'
    if (reason.indexOf('hash_mismatch') >= 0) return 'TRN-HASH-001'
    if (reason.indexOf('archive') >= 0 || reason.indexOf('decompress') >= 0) return 'ARC-UNPACK-001'
    return 'TRN-RECV-002'
  }

  userMessageForReason(reason: string): string {
    if (reason.indexOf('insufficient_space') >= 0) return '存储空间不足，请清理空间后点击重试'
    if (reason.indexOf('hash_mismatch') >= 0) return '文件校验失败，可由发送端重试'
    if (reason.indexOf('archive') >= 0 || reason.indexOf('decompress') >= 0) return '文件夹归档无效或解压失败'
    return `接收失败：${reason}`
  }

  async startDiscovery(): Promise<void> {
    if (!this.host.discoveryEnabled) {
      return
    }
    if (this.host.discoveryService) {
      return
    }
    this.host.discoveryService = new DiscoveryService(
      this.host.deviceId,
      this.host.identityFingerprint,
      (device: DeviceInfo): boolean =>
        this.host.identityMatches(device.deviceId, device.identityFingerprint),
    )
    try {
      const knownTargets = this.host.targetIp.length > 0 ? [this.host.targetIp] : []
      await this.host.discoveryService.start(this.host.localDeviceName(), this.host.localTcpPort, this.host.discoveryPort,
        this.host.localIp, this.host.networkName,
        this.host.localSystemVersion(), {
        onDevice: (device: DeviceInfo) => {
          // 缺少身份指纹的数据包只能视为未验证，不能据此认定已配对设备更换了身份。
          // 只有收到明确且不同的指纹时，才可以撤销本地信任。
          if (this.host.isTrusted(device.deviceId) && device.identityFingerprint &&
            device.identityFingerprint.length > 0 &&
            !this.host.identityMatches(device.deviceId, device.identityFingerprint)) {
            this.host.trustedDeviceIds = this.host.trustedDeviceIds.filter((id: string) => id !== device.deviceId)
            this.host.trustedFingerprints.delete(device.deviceId)
            this.host.selectedDeviceIds = this.host.selectedDeviceIds.filter((id: string) => id !== device.deviceId)
            this.host.statusText = `设备身份已变化，请重新配对：${device.deviceName}`
            this.host.transferStore.recordDiagnostic(
              'PAIR-IDENTITY-CHANGED', 'stored fingerprint mismatch'
            ).catch(() => {})
          }
          this.host.deviceLastSeenAt.set(device.deviceId, Date.now())
          if (device.acknowledgedDeviceId === this.host.deviceId) {
            this.host.confirmedDeviceLastSeenAt.set(device.deviceId, Date.now())
          }
          const filtered = this.host.nearbyDevices.filter((item: DeviceInfo) => item.deviceId !== device.deviceId)
          filtered.push(device)
          filtered.sort((left: DeviceInfo, right: DeviceInfo) => left.deviceName.localeCompare(right.deviceName))
          this.host.nearbyDevices = filtered

          if (this.host.isTrusted(device.deviceId)) {
            this.host.rememberDevice(device).catch(() => {})
          }

          if (device.platform === 'macOS' && this.host.isTrusted(device.deviceId) &&
            this.isBidirectionallyAlive(device.deviceId)) {
            if (this.host.selectedDeviceIds.length === 0) {
              this.selectDevice(device)
            } else {
              // 不把单设备任务静默扩大为“发送给全部设备”。
              this.resumeWaitingTransfers(device)
            }
          }
        },
        onStatus: (value: string) => {
          this.host.statusText = value
        },
      }, knownTargets)
    } catch (err) {
      this.host.discoveryService = undefined
      this.host.transferStore.recordDiagnostic('TRN-DISC-001', errorText(err)).catch(() => {})
      this.host.statusText = `发现服务启动失败：${errorText(err)}`
    }
  }

  startDevicePruning(): void {
    if (this.host.pruneTimer !== undefined) {
      return
    }
    this.host.pruneTimer = setInterval(() => {
      this.pruneStaleDevices()
    }, DEVICE_PRUNE_INTERVAL_MS)
  }

  clearLifecycleTimers(): void {
    if (this.host.pruneTimer !== undefined) {
      clearInterval(this.host.pruneTimer)
      this.host.pruneTimer = undefined
    }
    if (this.host.pairingTimer !== undefined) {
      clearInterval(this.host.pairingTimer)
      this.host.pairingTimer = undefined
    }
    if (this.host.persistenceTimer !== undefined) {
      clearTimeout(this.host.persistenceTimer)
      this.host.persistenceTimer = undefined
    }
  }

  async restartDiscovery(): Promise<void> {
    await this.refreshNetworkName()
    if (!this.host.discoveryEnabled) {
      await this.stopDiscovery()
      return
    }
    if (this.host.discoveryService) {
      await this.host.discoveryService.stop()
      this.host.discoveryService = undefined
    }
    this.host.nearbyDevices = []
    this.host.deviceLastSeenAt.clear()
    this.host.confirmedDeviceLastSeenAt.clear()
    if (this.host.selectedDeviceId.length > 0) {
      this.host.selectedDeviceId = ''
    }
    await this.startDiscovery()
  }

  /** 网络切换后重新绑定发现与接收服务，避免继续使用旧网卡地址。 */
  handleNetworkChanged(): void {
    this.host.runOnUi(() => {
      this.host.statusText = '网络已变化，正在重新发现设备'
      this.host.transferService.stopReceive().then(() => this.stopDiscovery())
        .then(() => this.ensureReceiverAndDiscovery())
        .catch((err: Error) => {
          this.host.statusText = `网络服务恢复失败：${errorText(err)}`
        })
    })
  }

  async refreshNetworkName(): Promise<void> {
    try {
      const linkedInfo = await wifiManager.getLinkedInfo()
      this.host.networkName = linkedInfo.ssid.length > 0 ? linkedInfo.ssid : '未连接 Wi-Fi'
      this.host.localIp = wifiIpAddress(wifiManager.getIpInfo().ipAddress)
    } catch (_err) {
      this.host.networkName = '未获取到网络名称'
      this.host.localIp = ''
    }
    try {
      const systemName = settings.getValueSync(this.host.abilityContext(), settings.general.DEVICE_NAME, '').trim()
      if (systemName.length > 0) this.host.localDeviceDisplayName = systemName
    } catch (_err) {
    }
  }

  async stopDiscovery(): Promise<void> {
    if (this.host.discoveryService) {
      await this.host.discoveryService.stop()
      this.host.discoveryService = undefined
    }
    this.host.nearbyDevices = []
    this.host.deviceLastSeenAt.clear()
    this.host.confirmedDeviceLastSeenAt.clear()
    if (this.host.selectedDeviceId.length > 0) {
      this.host.selectedDeviceId = ''
    }
  }

  pruneStaleDevices(): void {
    const now = Date.now()
    const fresh = this.host.nearbyDevices.filter((device: DeviceInfo) => {
      return now - (this.host.deviceLastSeenAt.get(device.deviceId) ?? 0) < DEVICE_TTL_MS
    })
    const freshDeviceIds = fresh.map((device: DeviceInfo) => device.deviceId)
    this.host.deviceLastSeenAt.forEach((_lastSeenAt: number, deviceId: string) => {
      if (freshDeviceIds.indexOf(deviceId) < 0) {
        this.host.deviceLastSeenAt.delete(deviceId)
      }
    })
    this.host.confirmedDeviceLastSeenAt.forEach((lastSeenAt: number, deviceId: string) => {
      if (freshDeviceIds.indexOf(deviceId) < 0 || now - lastSeenAt >= DEVICE_TTL_MS) {
        this.host.confirmedDeviceLastSeenAt.delete(deviceId)
      }
    })
    if (fresh.length !== this.host.nearbyDevices.length) {
      this.host.nearbyDevices = fresh
    }
    if (this.host.selectedDeviceId.length > 0 && !fresh.some((device: DeviceInfo) => device.deviceId === this.host.selectedDeviceId)) {
      this.host.selectedDeviceId = ''
    }
    this.host.selectedDeviceIds = this.host.selectedDeviceIds.filter((deviceId: string) => {
      return fresh.some((device: DeviceInfo) => device.deviceId === deviceId) &&
        this.isBidirectionallyAlive(deviceId)
    })
  }

  selectDevice(device: DeviceInfo): void {
    if (!this.host.isTrusted(device.deviceId)) {
      this.beginPairing(device)
      return
    }
    this.host.selectedDeviceId = device.deviceId
    if (this.host.selectedDeviceIds.indexOf(device.deviceId) < 0) {
      this.host.selectedDeviceIds = this.host.selectedDeviceIds.concat([device.deviceId])
    }
    this.host.targetIp = device.ip
    this.host.portText = `${device.port}`
    this.host.statusText = this.isBidirectionallyAlive(device.deviceId) ?
      `已连接：${device.deviceName}` : `已选择 ${device.deviceName}，正在等待对端确认`
    this.host.saveTarget()
    this.resumeWaitingTransfers(device)
  }

  /** “已连接”要求对端明确确认本 Pad，不能仅凭收到一次广播判定。 */
  isBidirectionallyAlive(deviceId: string): boolean {
    return Date.now() - (this.host.confirmedDeviceLastSeenAt.get(deviceId) ?? 0) < DEVICE_TTL_MS
  }

  // MARK: 配对与传输目标选择

  toggleTransferTarget(device: DeviceInfo): void {
    if (!this.host.isTrusted(device.deviceId)) {
      this.beginPairing(device)
      return
    }
    const selected = this.host.selectedDeviceIds.indexOf(device.deviceId) >= 0
    if (selected && this.host.selectedDeviceIds.length > 1) {
      this.host.selectedDeviceIds = this.host.selectedDeviceIds.filter((id: string) => id !== device.deviceId)
      this.host.statusText = `已取消选择：${device.deviceName}`
      return
    }
    if (!selected) {
      this.host.selectedDeviceIds = this.host.selectedDeviceIds.concat([device.deviceId])
    }
    this.host.selectedDeviceId = device.deviceId
    this.host.targetIp = device.ip
    this.host.portText = `${device.port}`
    this.host.statusText = `已选择发送目标：${device.deviceName}`
  }

  resumeWaitingTransfers(device: DeviceInfo): void {
    const sameNameCount = this.host.nearbyDevices.filter((candidate: DeviceInfo) =>
      candidate.deviceName === device.deviceName).length
    const candidates = this.host.currentTransfers.filter((item: TransferListItem) => {
      const hasSource = this.host.archiveService.sourceExists(item.stagingPath)
      const routesToDevice = item.deviceId.length > 0 ? item.deviceId === device.deviceId :
        item.peerName === device.deviceName && sameNameCount === 1
      return item.direction === '发送' && item.state === TransferState.Waiting && hasSource &&
        routesToDevice && !this.host.activeTransferDeviceIds.has(item.id)
    })
    candidates.forEach((item: TransferListItem) => {
      this.host.activeTransferDeviceIds.set(item.id, device.deviceId)
      this.host.markCurrentTransferState(item.id, TransferState.Preparing, '设备已恢复，正在协商断点')
      this.resumeTransferItem(item, device).catch((err: Error) => {
        this.host.runOnUi(() => {
          this.host.activeTransferDeviceIds.delete(item.id)
          const detail = errorText(err)
          if (detail.indexOf('Persistent staging source is missing') >= 0 || detail.indexOf('13900002') >= 0) {
            this.host.completeTransfer(item.id, false, '源文件不可用，请重新选择文件发送')
          } else {
            this.host.markCurrentTransferState(item.id, TransferState.Waiting, '网络仍未恢复，稍后自动重试')
          }
        })
      })
    })
  }

  async resumeTransferItem(item: TransferListItem, device: DeviceInfo): Promise<void> {
    if (!this.host.archiveService.sourceExists(item.stagingPath)) {
      throw new Error('Persistent staging source is missing')
    }
    const source = this.host.archiveService.restore(item.stagingPath ?? '', item.localPath, item.fileName,
      item.fileSize, item.fileType, item.sourceSize, item.sourceFileCount)
    await this.host.sendPreparedSource(source, device, item.id, item.groupId)
  }

  beginPairing(device: DeviceInfo): void {
    if (!device.identityFingerprint || device.identityFingerprint.length === 0) {
      this.host.statusText = '对端版本过旧或身份信息缺失，请将两端升级到 v0.2 后重新配对'
      return
    }
    this.host.pairingTarget = device
    this.host.pairingInput = ''
    this.host.statusText = `等待输入 ${device.deviceName} 的六位配对码`
  }

  reconnectTrustedDevice(device: DeviceInfo): void {
    if (!this.host.discoveryEnabled) {
      this.host.statusText = '请先开启连接服务'
      return
    }
    this.host.targetIp = device.ip
    this.host.portText = `${device.port}`
    this.host.statusText = `正在重新连接：${device.deviceName}`
    this.host.saveTarget()
    this.restartDiscovery().catch((err: Error) => {
      this.host.statusText = `重新连接失败：${errorText(err)}`
    })
    setTimeout(() => {
      if (!this.host.isTrusted(device.deviceId) || this.isBidirectionallyAlive(device.deviceId)) return
      const fresh = this.host.nearbyDevices.find((item: DeviceInfo) => item.deviceId === device.deviceId)
      if (!fresh) {
        this.host.statusText = `设备当前不在线：${device.deviceName}`
        return
      }
      this.host.forgetTrustedDevice(device.deviceId, '对端未确认原配对关系，需要重新输入配对码')
        .then(() => this.beginPairing(fresh))
        .catch((err: Error) => { this.host.statusText = `重新配对准备失败：${errorText(err)}` })
    }, 4500)
  }

  /** 用户主动移除设备时，先发出远端撤销通知，再立即清除本机状态。 */
  async forgetDevice(device: DeviceInfo): Promise<void> {
    const request = createUnpairRequest(
      this.host.deviceId,
      this.host.identityFingerprint,
      device.deviceId,
    )
    this.notifyUnpairWithRetry(device, request)
    await this.host.forgetTrustedDevice(device.deviceId, `已移除设备：${device.deviceName}`)
  }

  async submitPairing(): Promise<void> {
    const device = this.host.pairingTarget
    if (!device || this.host.pairingInput.length !== 6) {
      this.host.statusText = '请输入六位配对码'
      return
    }
    try {
      this.host.statusText = `正在校验 ${device.deviceName} 的配对码`
      const request = createPairingRequest(
        this.host.deviceId,
        this.host.localDeviceName(),
        'HarmonyOS',
        this.host.localSystemVersion(),
        this.host.localIp.length > 0 ? this.host.localIp : '0.0.0.0',
        this.host.localTcpPort,
        this.host.pairingInput,
        this.host.identityFingerprint
      )
      const response = await this.host.transferService.requestPairing(device.ip, device.port, request)
      if (!response.accepted) {
        this.host.statusText = response.reason === 'protocol_incompatible' ?
          '配对失败：双端协议版本不一致，请更新到同一版本' : '配对失败：配对码错误或已过期'
        return
      }
      await this.host.trustDevice(device.deviceId, device.identityFingerprint)
      await this.host.rememberDevice(device)
      this.host.pairingTarget = undefined
      this.host.pairingInput = ''
      this.selectDevice(device)
      this.host.statusText = `配对成功，正在确认连接：${device.deviceName}`
      this.host.showToast(`已与 ${device.deviceName} 完成配对`)
    } catch (err) {
      const detail = errorText(err)
      this.host.statusText = `配对失败：无法连接对方接收服务（${detail}）`
      this.host.showToast('配对失败，请确认 Mac 接收服务正在运行')
    }
  }

  private notifyUnpairWithRetry(device: DeviceInfo, request: UnpairRequest): void {
    const notify = async (): Promise<void> => {
      let finalError = ''
      for (let attempt = 0; attempt < 2; attempt += 1) {
        try {
          const response = await this.host.transferService.requestUnpair(device.ip, device.port, request)
          if (response.accepted) return
          await this.host.transferStore.recordDiagnostic(
            'PAIR-UNPAIR-REJECTED', response.reason ?? 'remote rejected unpair', undefined,
          )
          return
        } catch (err) {
          finalError = errorText(err)
          if (attempt === 0) await new Promise<void>((resolve) => setTimeout(resolve, 600))
        }
      }
      await this.host.transferStore.recordDiagnostic('PAIR-UNPAIR-NOTIFY', finalError, undefined)
    }
    notify().catch(() => {})
  }

}
