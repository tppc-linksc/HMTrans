import { cryptoFramework } from '@kit.CryptoArchitectureKit'
import { arrayBufferToString, stringToArrayBuffer } from './Bytes'
import { errorText } from './ErrorText'

export const CAST_HEADER_LENGTH: number = 32
export const CAST_PROTOCOL_VERSION: string = '0.3.0'
export const CAST_MAX_CONTROL_BYTES: number = 64 * 1024
export const CAST_MAX_MEDIA_BYTES: number = 8 * 1024 * 1024
export const CAST_HEARTBEAT_INTERVAL_MS: number = 2000
export const CAST_HEARTBEAT_TIMEOUT_MS: number = 6000

export enum CastMessageType {
  HELLO = 1,
  ACK = 2,
  VIDEO_CONFIG = 3,
  VIDEO_FRAME = 4,
  STREAM_CONTROL = 5,
  HEARTBEAT = 6,
  ERROR = 7,
  END = 8,
}

export enum CastPacketFlags {
  NONE = 0,
  ENCRYPTED = 1,
  KEY_FRAME = 2,
  CODEC_CONFIG = 4,
}

export interface CastPacket {
  type: CastMessageType
  flags: number
  sequence: number
  ptsUs: number
  payloadLength: number
}

export interface CastHello {
  app: string
  protocol: string
  deviceId: string
  deviceName: string
  identityFingerprint: string
  sessionId: string
  codec: string
  width: number
  height: number
  frameRate: number
}

export interface CastAck {
  accepted: boolean
  sessionId: string
  reason?: string
}

/** 持久配对密钥只在两台已配对设备之间保存；投屏会为每个包使用独立随机 nonce。 */
export class ScreenCastCipher {
  private key: cryptoFramework.SymKey

  constructor(secretHex: string) {
    const keyBytes = hexToBytes(secretHex)
    if (keyBytes.length !== 32) throw new Error('投屏配对密钥无效，请删除设备后重新配对')
    const generator = cryptoFramework.createSymKeyGenerator('AES256')
    this.key = generator.convertKeySync({ data: keyBytes })
  }

  async encrypt(plain: ArrayBuffer, aad: ArrayBuffer): Promise<ArrayBuffer> {
    try {
      const nonce = cryptoFramework.createRandom().generateRandomSync(12).data
      const params: cryptoFramework.GcmParamsSpec = {
        algName: 'GcmParamsSpec',
        iv: { data: nonce },
        aad: { data: new Uint8Array(aad) },
        authTag: { data: new Uint8Array(16) },
      }
      const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding')
      await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, this.key, params)
      const encrypted = await cipher.doFinal({ data: new Uint8Array(plain) })
      return concatBuffers([nonce.buffer, encrypted.data.buffer, params.authTag.data.buffer])
    } catch (err) {
      throw new Error(`投屏数据加密失败：${errorText(err)}`)
    }
  }

  async decrypt(sealed: ArrayBuffer, aad: ArrayBuffer): Promise<ArrayBuffer> {
    if (sealed.byteLength < 28) throw new Error('投屏加密包长度无效')
    try {
      const bytes = new Uint8Array(sealed)
      const nonce = bytes.slice(0, 12)
      const tag = bytes.slice(bytes.length - 16)
      const ciphertext = bytes.slice(12, bytes.length - 16)
      const params: cryptoFramework.GcmParamsSpec = {
        algName: 'GcmParamsSpec',
        iv: { data: nonce },
        aad: { data: new Uint8Array(aad) },
        authTag: { data: tag },
      }
      const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding')
      await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, this.key, params)
      const plain = await cipher.doFinal({ data: ciphertext })
      return plain.data.buffer
    } catch (err) {
      throw new Error(`投屏数据解密失败：${errorText(err)}`)
    }
  }
}

export function encodeCastJson(value: object): ArrayBuffer {
  return stringToArrayBuffer(JSON.stringify(value))
}

export function decodeCastJson<T>(value: ArrayBuffer): T {
  return JSON.parse(arrayBufferToString(value)) as T
}

export function buildCastHeader(type: CastMessageType, flags: number, payloadLength: number,
  sequence: number, ptsUs: number): ArrayBuffer {
  if (type < CastMessageType.HELLO || type > CastMessageType.END || (flags & 0xF8) !== 0) {
    throw new Error('投屏帧头参数无效')
  }
  const encryptedOverhead = (flags & CastPacketFlags.ENCRYPTED) !== 0 ? 28 : 0
  const limit = (type === CastMessageType.VIDEO_FRAME ? CAST_MAX_MEDIA_BYTES : CAST_MAX_CONTROL_BYTES) +
    encryptedOverhead
  if (!Number.isSafeInteger(payloadLength) || payloadLength < 0 || payloadLength > limit) {
    throw new Error('投屏帧超过协议上限')
  }
  const buffer = new ArrayBuffer(CAST_HEADER_LENGTH)
  const view = new DataView(buffer)
  view.setUint8(0, 0x48); view.setUint8(1, 0x4D); view.setUint8(2, 0x43); view.setUint8(3, 0x53)
  view.setUint8(4, 0); view.setUint8(5, 3); view.setUint8(6, type); view.setUint8(7, flags)
  view.setUint16(8, CAST_HEADER_LENGTH, false); view.setUint16(10, 0, false)
  view.setUint32(12, payloadLength, false)
  writeUInt64(view, 16, sequence)
  writeUInt64(view, 24, ptsUs)
  return buffer
}

export function parseCastHeader(buffer: ArrayBuffer): CastPacket {
  if (buffer.byteLength < CAST_HEADER_LENGTH) throw new Error('投屏帧头不完整')
  const view = new DataView(buffer)
  if (view.getUint8(0) !== 0x48 || view.getUint8(1) !== 0x4D ||
    view.getUint8(2) !== 0x43 || view.getUint8(3) !== 0x53) throw new Error('投屏魔数无效')
  if (view.getUint8(4) !== 0 || view.getUint8(5) !== 3 || view.getUint16(8, false) !== CAST_HEADER_LENGTH ||
    view.getUint16(10, false) !== 0) {
    throw new Error('投屏协议版本不兼容')
  }
  const length = view.getUint32(12, false)
  const rawType = view.getUint8(6)
  const flags = view.getUint8(7)
  if (rawType < CastMessageType.HELLO || rawType > CastMessageType.END || (flags & 0xF8) !== 0) {
    throw new Error('投屏帧头参数无效')
  }
  const type = rawType as CastMessageType
  const encryptedOverhead = (flags & CastPacketFlags.ENCRYPTED) !== 0 ? 28 : 0
  const limit = (type === CastMessageType.VIDEO_FRAME ? CAST_MAX_MEDIA_BYTES : CAST_MAX_CONTROL_BYTES) +
    encryptedOverhead
  if (length > limit) throw new Error('投屏帧超过协议上限')
  return {
    type,
    flags,
    sequence: readUInt64(view, 16),
    ptsUs: readUInt64(view, 24),
    payloadLength: length,
  }
}

export function castPacket(type: CastMessageType, flags: number, payload: ArrayBuffer,
  sequence: number, ptsUs: number): ArrayBuffer {
  return concatBuffers([buildCastHeader(type, flags, payload.byteLength, sequence, ptsUs), payload])
}

export function concatBuffers(buffers: Array<ArrayBuffer>): ArrayBuffer {
  const length = buffers.reduce((sum: number, item: ArrayBuffer) => sum + item.byteLength, 0)
  const result = new Uint8Array(length)
  let offset = 0
  buffers.forEach((item: ArrayBuffer) => {
    result.set(new Uint8Array(item), offset)
    offset += item.byteLength
  })
  return result.buffer
}

export function hexToBytes(value: string): Uint8Array {
  const normalized = value.trim().toLowerCase()
  if (normalized.length % 2 !== 0 || !/^[0-9a-f]+$/.test(normalized)) return new Uint8Array()
  const result = new Uint8Array(normalized.length / 2)
  for (let index = 0; index < result.length; index++) {
    result[index] = Number.parseInt(normalized.substring(index * 2, index * 2 + 2), 16)
  }
  return result
}

function writeUInt64(view: DataView, offset: number, value: number): void {
  const safe = Math.max(0, Math.floor(value))
  view.setUint32(offset, Math.floor(safe / 0x100000000), false)
  view.setUint32(offset + 4, safe % 0x100000000, false)
}

function readUInt64(view: DataView, offset: number): number {
  return view.getUint32(offset, false) * 0x100000000 + view.getUint32(offset + 4, false)
}
