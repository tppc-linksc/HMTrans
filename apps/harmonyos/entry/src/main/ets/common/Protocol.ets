export const APP_NAME: string = 'HMTrans'
export const PROTOCOL_VERSION: string = '0.1.0'
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
}

export interface ReceiveDecision {
  type: 'receive_decision'
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
}

export function encodeJsonLine(value: object): string {
  return JSON.stringify(value) + '\n'
}

export function createReceiveDecision(accepted: boolean, reason?: string): ReceiveDecision {
  return {
    type: 'receive_decision',
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
  senderPlatform?: string
): FileMeta {
  const totalChunks = Math.ceil(fileSize / DEFAULT_CHUNK_SIZE)
  return {
    type: 'file_meta',
    app: APP_NAME,
    version: PROTOCOL_VERSION,
    transferId: `${Date.now()}-${Math.floor(Math.random() * 1000000)}`,
    senderDeviceId: senderDeviceId,
    senderName: senderName,
    senderPlatform: senderPlatform,
    fileName,
    fileSize,
    sha256,
    chunkSize: DEFAULT_CHUNK_SIZE,
    totalChunks,
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

export function createDeviceInfo(deviceName: string, port: number, deviceId: string): DeviceInfo {
  return {
    app: APP_NAME,
    version: PROTOCOL_VERSION,
    deviceName,
    platform: 'HarmonyOS',
    ip: '0.0.0.0',
    port,
    deviceId,
  }
}
