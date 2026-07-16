import { common } from '@kit.AbilityKit'
import { DeviceInfo, FileMeta } from '../common/Protocol'
import { TransferListItem, TransferListItemOptions } from '../models/TransferListItem'
import { ArchiveService, SendableSource } from '../services/ArchiveService'
import { DiscoveryService } from '../services/DiscoveryService'
import { TcpTransferService } from '../services/TcpTransferService'
import { TransferStore } from '../persistence/TransferStore'

/** 网络控制器依赖的服务和非响应式运行时状态。 */
export interface PadNetworkRuntimeHost {
  transferService: TcpTransferService
  transferStore: TransferStore
  archiveService: ArchiveService
  discoveryService?: DiscoveryService
  deviceId: string
  identityFingerprint: string
  receiveDirectory: string
  trustedFingerprints: Map<string, string>
  trustedSharedSecrets: Map<string, string>
  deviceLastSeenAt: Map<string, number>
  confirmedDeviceLastSeenAt: Map<string, number>
  activeTransferDeviceIds: Map<string, string>
  pruneTimer?: number
  pairingTimer?: number
  persistenceTimer?: number
  localTcpPort: number
  discoveryPort: number
  castPort: number
}

/** 网络与配对流程会直接更新的响应式页面状态。 */
export interface PadNetworkStateHost {
  targetIp: string
  portText: string
  statusText: string
  networkName: string
  localIp: string
  localDeviceDisplayName: string
  nearbyDevices: Array<DeviceInfo>
  selectedDeviceId: string
  selectedDeviceIds: Array<string>
  trustedDeviceIds: Array<string>
  currentTransfers: Array<TransferListItem>
  pairingCode: string
  pairingSeconds: number
  pairingTarget: DeviceInfo | undefined
  pairingInput: string
  receiverEnabled: boolean
  discoveryEnabled: boolean
  autoReceiveTrustedEnabled: boolean
  receiverReady: boolean
}

/** 网络控制器调用的页面能力和跨控制器动作。 */
export interface PadNetworkActionHost {
  abilityContext(): common.UIAbilityContext
  localDeviceName(): string
  localSystemVersion(): string
  runOnUi(task: () => void): void
  updateBackgroundTransferActivity(active: boolean): void
  trustDevice(deviceId?: string, fingerprint?: string, sharedSecret?: string): Promise<void>
  forgetTrustedDevice(deviceId: string, statusMessage: string): Promise<void>
  rememberDevice(device: DeviceInfo): Promise<void>
  isTrusted(deviceId?: string): boolean
  identityMatches(deviceId?: string, fingerprint?: string): boolean
  saveTarget(): Promise<void>
  sendPreparedSource(source: SendableSource, device: DeviceInfo, reuseTransferId?: string,
    groupId?: string, cleanupSource?: boolean): Promise<boolean>
  markCurrentTransferState(id: string, state: string, detail: string): void
  completeTransfer(id: string, success: boolean, detail: string, localPath?: string): void
  updateCurrentTransfer(id: string, progress: number, detail: string): void
  upsertCurrentTransfer(item: TransferListItemOptions): void
  progressDetail(id: string, current: number, total: number): string
  historyDeviceIdForIncoming(meta: FileMeta): string
  markReceivedFilePublished(transferId: string, fileName: string, path: string): Promise<void>
  updateHistoryDetail(id: string, detailPrefix: string): void
  showToast(message: string): void
  confirmReceive(sender: string, fileName: string, sizeText: string): Promise<boolean>
}

/** 按职责组合控制器所需能力，避免维护单个超大接口。 */
export interface PadNetworkHost extends PadNetworkRuntimeHost, PadNetworkStateHost, PadNetworkActionHost {}
