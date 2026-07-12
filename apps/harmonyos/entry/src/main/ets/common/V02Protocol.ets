export const V02_PROTOCOL_VERSION: string = '0.2.0'
export const V02_PROTOCOL_MIN: string = '0.1.0'

export interface V02MessageHeader {
  type: string
  app: string
  protocolVersion: string
  messageId: string
  timestamp: number
}

export interface V02DiscoveryBeacon {
  type: 'discovery_beacon'
  app: string
  protocolMin: string
  protocolMax: string
  deviceId: string
  deviceName: string
  platform: string
  systemVersion: string
  ip: string
  port: number
  receiverState: 'ready' | 'send_only' | 'disabled' | 'error'
  pairingRequired: boolean
  capabilities: Array<string>
  timestamp: number
}

export interface V02TransferOffer extends V02MessageHeader {
  transferId: string
  groupId?: string
  senderDeviceId: string
  receiverDeviceId: string
  sourceKind: 'file' | 'folder'
  payloadKind: 'raw' | 'zip'
  displayName: string
  sourceSize: number
  sourceFileCount: number
  payloadSize: number
  payloadSha256: string
  chunkSize: number
  resumeSupported: boolean
}

export interface V02TransferAccept extends V02MessageHeader {
  transferId: string
  resumeOffset: number
  lastCompleteChunkSha256?: string
  reservedName: string
}

export interface V02TransferCommand extends V02MessageHeader {
  transferId: string
  command: 'pause' | 'resume' | 'cancel'
  deletePartial: boolean
}

export interface V02TransferResult extends V02MessageHeader {
  transferId: string
  success: boolean
  payloadSha256?: string
  savedName?: string
  reason?: string
  retryable: boolean
}

export function createV02Header(type: string): V02MessageHeader {
  return {
    type,
    app: 'HMTrans',
    protocolVersion: V02_PROTOCOL_VERSION,
    messageId: `${Date.now()}-${Math.floor(Math.random() * 1000000)}`,
    timestamp: Date.now(),
  }
}
