import { cryptoFramework } from '@kit.CryptoArchitectureKit'
import { arrayBufferToString, stringToArrayBuffer, toHex } from './Bytes'
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
  NETWORK_TEST_HELLO = 9,
  NETWORK_TEST_DATA = 10,
  NETWORK_TEST_PING = 11,
  NETWORK_TEST_PONG = 12,
  NETWORK_TEST_RESULT = 13,
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

export interface CastNetworkTestHello {
  app: string
  protocol: string
  deviceId: string
  deviceName: string
  identityFingerprint: string
  sessionId: string
  payloadBytes: number
}

export interface CastNetworkTestPing {
  index: number
  sentAtMs: number
}

export interface CastNetworkTestResult {
  sessionId: string
  receivedBytes: number
  durationMs: number
  throughputMbps: number
  averageRttMs: number
  jitterMs: number
  recommendation: string
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
      // API 22+ 的同步入口会直接在当前投屏发送任务中完成小帧加密，避免每一帧都
      // 经过异步任务调度并挤压媒体发送与心跳处理。
      cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, this.key, params)
      const encrypted = cipher.doFinalSync({ data: new Uint8Array(plain) })
      const encryptedBytes = encrypted.data
      // HarmonyOS 6.1 的 GCM doFinalSync 返回 ciphertext || authTag；部分 SDK 实现
      // 则只返回 ciphertext 并把 tag 写回 params.authTag。不能无条件再追加 tag，
      // 否则线上包会比帧头声明多 16 字节，接收端下一帧必然从错误偏移解析。
      if (encryptedBytes.byteLength === plain.byteLength + 16) {
        return concatBuffers([exactArrayBuffer(nonce), exactArrayBuffer(encryptedBytes)])
      }
      if (encryptedBytes.byteLength === plain.byteLength && params.authTag.data.byteLength === 16) {
        return concatBuffers([
          exactArrayBuffer(nonce),
          exactArrayBuffer(encryptedBytes),
          exactArrayBuffer(params.authTag.data),
        ])
      }
      throw new Error(`AES-GCM 输出长度异常：${encryptedBytes.byteLength}`)
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
      cipher.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, this.key, params)
      const plain = cipher.doFinalSync({ data: ciphertext })
      return exactArrayBuffer(plain.data)
    } catch (err) {
      throw new Error(`投屏数据解密失败：${errorText(err)}`)
    }
  }
}

/** 控制端口的投屏启动请求使用同一配对密钥做 HMAC，不传输也不记录密钥。 */
export function screenCastControlSignature(secretHex: string, canonicalText: string): string {
  try {
    const keyBytes = hexToBytes(secretHex)
    if (keyBytes.length !== 32) throw new Error('投屏配对密钥无效，请删除设备后重新配对')
    const generator = cryptoFramework.createSymKeyGenerator('HMAC')
    const key = generator.convertKeySync({ data: keyBytes })
    const mac = cryptoFramework.createMac('SHA256')
    mac.initSync(key)
    mac.updateSync({ data: new Uint8Array(stringToArrayBuffer(canonicalText)) })
    return toHex(mac.doFinalSync().data)
  } catch (err) {
    throw new Error(`投屏控制请求认证失败：${errorText(err)}`)
  }
}

export function secureHexEquals(lhs: string, rhs: string): boolean {
  const left = hexToBytes(lhs)
  const right = hexToBytes(rhs)
  if (left.length === 0 || left.length !== right.length) return false
  let difference = 0
  for (let index = 0; index < left.length; index++) difference |= left[index] ^ right[index]
  return difference === 0
}

/** Uint8Array 可能只是较大底层缓冲区的视图，协议层必须只发送当前视图范围。 */
function exactArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const result = new Uint8Array(bytes.byteLength)
  result.set(bytes)
  return result.buffer
}

export function encodeCastJson(value: object): ArrayBuffer {
  return stringToArrayBuffer(JSON.stringify(value))
}

export function decodeCastJson<T>(value: ArrayBuffer): T {
  return JSON.parse(arrayBufferToString(value)) as T
}

export function buildCastHeader(type: CastMessageType, flags: number, payloadLength: number,
  sequence: number, ptsUs: number): ArrayBuffer {
  if (type < CastMessageType.HELLO || type > CastMessageType.NETWORK_TEST_RESULT || (flags & 0xF8) !== 0) {
    throw new Error('投屏帧头参数无效')
  }
  const encryptedOverhead = (flags & CastPacketFlags.ENCRYPTED) !== 0 ? 28 : 0
  const limit = (type === CastMessageType.VIDEO_FRAME || type === CastMessageType.NETWORK_TEST_DATA ?
    CAST_MAX_MEDIA_BYTES : CAST_MAX_CONTROL_BYTES) +
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
  if (rawType < CastMessageType.HELLO || rawType > CastMessageType.NETWORK_TEST_RESULT || (flags & 0xF8) !== 0) {
    throw new Error('投屏帧头参数无效')
  }
  const type = rawType as CastMessageType
  const encryptedOverhead = (flags & CastPacketFlags.ENCRYPTED) !== 0 ? 28 : 0
  const limit = (type === CastMessageType.VIDEO_FRAME || type === CastMessageType.NETWORK_TEST_DATA ?
    CAST_MAX_MEDIA_BYTES : CAST_MAX_CONTROL_BYTES) +
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
