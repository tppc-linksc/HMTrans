export const APP_NAME: string = 'HMTrans'
export const PROTOCOL_VERSION: string = '0.2.0'
export const DEFAULT_PORT: number = 51888
export const DEFAULT_CHUNK_SIZE: number = 1048576
export const DISCOVERY_PORT: number = 51889

export interface FileMeta {
  type: 'file_meta'
  app: string
  version: string
  transferId: string
  senderDeviceId?: string
  senderName?: string
  senderPlatform?: string
  fileName: string
  fileSize: number
  sha256: string
  chunkSize: number
  totalChunks: number
  resumeSupported?: boolean
  sourceKind?: string
  payloadKind?: string
  sourceName?: string
  sourceSize?: number
  sourceFileCount?: number
  senderFingerprint?: string
}

export interface ReceiveDecision {
  type: 'receive_decision'
  accepted: boolean
  reason?: string | null
  resumeOffset?: number
}

export interface PairingRequest {
  type: 'pairing_request'
  app: string
  version: string
  requesterDeviceId: string
  requesterName: string
  requesterPlatform: string
  requesterSystemVersion: string
  requesterIP: string
  requesterPort: number
  code: string
  requesterFingerprint?: string
}

export interface PairingResponse {
  type: 'pairing_response'
  accepted: boolean
  reason?: string | null
}

/** 已配对设备主动通知对端撤销双方的本地信任关系。 */
export interface UnpairRequest {
  type: 'unpair_request'
  app: string
  version: string
  requesterDeviceId: string
  requesterFingerprint: string
  targetDeviceId: string
}

export interface UnpairResponse {
  type: 'unpair_response'
  accepted: boolean
  reason?: string | null
}

export interface TransferResult {
  type: 'transfer_success' | 'transfer_failed'
  transferId: string
  sha256?: string | null
  reason?: string | null
}

export interface DeviceInfo {
  app: string
  version: string
  deviceName: string
  platform: string
  ip: string
  port: number
  deviceId: string
  systemVersion?: string
  networkName?: string
  identityFingerprint?: string
  acknowledgedDeviceId?: string
}

export function encodeJsonLine(value: object): string {
  return JSON.stringify(value) + '\n'
}

export function createReceiveDecision(accepted: boolean, reason?: string, resumeOffset?: number): ReceiveDecision {
  return {
    type: 'receive_decision',
    accepted,
    reason: reason ?? null,
    resumeOffset,
  }
}

export function createPairingRequest(
  requesterDeviceId: string,
  requesterName: string,
  requesterPlatform: string,
  requesterSystemVersion: string,
  requesterIP: string,
  requesterPort: number,
  code: string,
  requesterFingerprint?: string
): PairingRequest {
  return {
    type: 'pairing_request',
    app: APP_NAME,
    version: PROTOCOL_VERSION,
    requesterDeviceId,
    requesterName,
    requesterPlatform,
    requesterSystemVersion,
    requesterIP,
    requesterPort,
    code: code.replace(/\D/g, ''),
    requesterFingerprint,
  }
}

export function createPairingResponse(accepted: boolean, reason?: string): PairingResponse {
  return {
    type: 'pairing_response',
    accepted,
    reason: reason ?? null,
  }
}

export function createUnpairRequest(requesterDeviceId: string, requesterFingerprint: string,
  targetDeviceId: string): UnpairRequest {
  return {
    type: 'unpair_request',
    app: APP_NAME,
    version: PROTOCOL_VERSION,
    requesterDeviceId,
    requesterFingerprint,
    targetDeviceId,
  }
}

export function createUnpairResponse(accepted: boolean, reason?: string): UnpairResponse {
  return {
    type: 'unpair_response',
    accepted,
    reason: reason ?? null,
  }
}

export function createFileMeta(
  fileName: string,
  fileSize: number,
  sha256: string,
  senderDeviceId?: string,
  senderName?: string,
  senderPlatform?: string,
  transferId?: string,
  sourceKind?: string,
  sourceName?: string,
  sourceSize?: number,
  sourceFileCount?: number,
  senderFingerprint?: string
): FileMeta {
  const totalChunks = Math.ceil(fileSize / DEFAULT_CHUNK_SIZE)
  return {
    type: 'file_meta',
    app: APP_NAME,
    version: PROTOCOL_VERSION,
    transferId: transferId ?? `${Date.now()}-${Math.floor(Math.random() * 1000000)}`,
    senderDeviceId: senderDeviceId,
    senderName: senderName,
    senderPlatform: senderPlatform,
    fileName,
    fileSize,
    sha256,
    chunkSize: DEFAULT_CHUNK_SIZE,
    totalChunks,
    resumeSupported: true,
    sourceKind: sourceKind ?? 'file',
    payloadKind: sourceKind === 'folder' ? 'zip' : 'file',
    sourceName: sourceName ?? fileName,
    sourceSize: sourceSize ?? fileSize,
    sourceFileCount: sourceFileCount ?? 1,
    senderFingerprint,
  }
}

export function createTransferResult(transferId: string, sha256: string | null, reason?: string): TransferResult {
  return {
    type: reason ? 'transfer_failed' : 'transfer_success',
    transferId,
    sha256,
    reason: reason ?? null,
  }
}

export function parseJsonLine<T>(line: string): T {
  return JSON.parse(line) as T
}

export function wifiIpAddress(value: number): string {
  const address = value >>> 0
  if (address === 0) return ''
  return `${(address >>> 24) & 0xFF}.${(address >>> 16) & 0xFF}.${(address >>> 8) & 0xFF}.${address & 0xFF}`
}

export function createDeviceInfo(deviceName: string, port: number, deviceId: string, localIp: string,
  networkName?: string, systemVersion?: string, identityFingerprint?: string,
  acknowledgedDeviceId?: string): DeviceInfo {
  return {
    app: APP_NAME,
    version: PROTOCOL_VERSION,
    deviceName,
    platform: 'HarmonyOS',
    ip: localIp.length > 0 ? localIp : '0.0.0.0',
    port,
    deviceId,
    systemVersion,
    networkName,
    identityFingerprint,
    acknowledgedDeviceId,
  }
}
