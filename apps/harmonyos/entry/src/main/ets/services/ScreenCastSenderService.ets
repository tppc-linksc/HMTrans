import { socket } from '@kit.NetworkKit'
import { util } from '@kit.ArkTS'
import screenCapture from 'libhmtrans_cast.so'
import { errorText } from '../common/ErrorText'
import {
  CAST_HEADER_LENGTH,
  CAST_HEARTBEAT_INTERVAL_MS,
  CAST_HEARTBEAT_TIMEOUT_MS,
  CAST_PROTOCOL_VERSION,
  CastAck,
  CastHello,
  CastMessageType,
  CastPacketFlags,
  ScreenCastCipher,
  buildCastHeader,
  castPacket,
  concatBuffers,
  decodeCastJson,
  encodeCastJson,
  parseCastHeader,
} from '../common/ScreenCastProtocol'

const MAX_QUEUED_FRAMES: number = 4
const MAX_QUEUED_BYTES: number = 32 * 1024 * 1024
const ACK_TIMEOUT_MS: number = 10000
const RECONNECT_WINDOW_MS: number = 10000
// 与 OH_AVCodecBufferFlags 保持一致，显式命名可以避免后续 SDK 升级时误读魔法数字。
const NATIVE_SYNC_FRAME_FLAG: number = 1 << 1
const NATIVE_CODEC_DATA_FLAG: number = 1 << 3

export type CastQuality = 'smooth' | 'balanced' | 'quality'
export type CastSenderState = 'idle' | 'connecting' | 'authorizing' | 'casting' | 'reconnecting' | 'failed'

export interface ScreenCastTarget {
  host: string
  port: number
  deviceId: string
  deviceName: string
  localDeviceId: string
  localDeviceName: string
  localFingerprint: string
  sharedSecret: string
  quality: CastQuality
}

export interface ScreenCastSenderCallbacks {
  onState: (state: CastSenderState, detail: string) => void
  onStatistics: (fps: number, bitrate: number, droppedFrames: number) => void
}

interface NativeFrame {
  data: ArrayBuffer
  ptsUs: number
  flags: number
}

interface CaptureOptions {
  width: number
  height: number
  frameRate: number
  bitrate: number
}

interface NativeCaptureStartResult {
  started: boolean
  stage: string
  errorCode: number
}

interface QueuedFrame {
  data: ArrayBuffer
  ptsUs: number
  flags: number
}

interface CastEndPayload {
  reason: string
}

interface CastVideoConfigPayload {
  codec: string
  width: number
  height: number
  frameRate: number
}

interface CastHeartbeatPayload {
  at: number
}

interface CastStreamControlPayload {
  command: string
}

interface NativeScreenCaptureModule {
  onFrame(callback: (frame: NativeFrame) => void): void
  onState(callback: (state: number, message: string) => void): void
  startCapture(options: CaptureOptions): NativeCaptureStartResult
  stopCapture(): void
  isCapturing(): boolean
}

/** 投屏发送器独占 51890 连接；四帧有界队列保证弱网时优先保持低延迟。 */
export class ScreenCastSenderService {
  private client?: socket.TCPSocket
  private callbacks?: ScreenCastSenderCallbacks
  private target?: ScreenCastTarget
  private cipher?: ScreenCastCipher
  private sessionId: string = ''
  private sequence: number = 1
  private queue: Array<QueuedFrame> = []
  private queuedBytes: number = 0
  private sending: boolean = false
  /**
   * HarmonyOS 的 TCPSocket.send 允许多个 Promise 同时在途，但不承诺这些异步调用按
   * 调用顺序完成。投屏帧和心跳共用同一个递增序号，因此必须在应用层串行写入；否则
   * Mac 会先收到较大的序号并把随后到达的帧判定为乱序，主动关闭连接。
   */
  private sendTail: Promise<void> = Promise.resolve()
  private stopped: boolean = true
  private heartbeatTimer?: number
  private lastMacActivityAt: number = 0
  private droppedFrames: number = 0
  private sentFrames: number = 0
  private sentBytes: number = 0
  private statisticsStartedAt: number = 0
  private captureOptions: CaptureOptions = qualityOptions('balanced')
  private reconnecting: boolean = false
  private mediaReady: boolean = false
  private waitingForKeyFrame: boolean = true
  private latestCodecConfig?: QueuedFrame
  private lastMacSequence: number = -1
  private state: CastSenderState = 'idle'
  private detail: string = '未在投屏'
  private fps: number = 0
  private bitrate: number = 0
  private nativeModule: NativeScreenCaptureModule = screenCapture as NativeScreenCaptureModule

  constructor() {
    this.nativeModule.onFrame((frame: NativeFrame) => this.enqueueFrame(frame))
    this.nativeModule.onState((state: number, message: string) => {
      if (state < 0 && !this.stopped) {
        const detail = message === 'screen_capture_ended_by_system' ? '系统已结束屏幕录制' :
          `系统投屏采集异常（${Math.abs(state)}）`
        this.fail(detail)
      }
      if (message === 'screen_capture_stopped_by_app') return
    })
  }

  async start(target: ScreenCastTarget, callbacks: ScreenCastSenderCallbacks): Promise<void> {
    if (!this.stopped) await this.stop('重新开始投屏')
    this.stopped = false
    this.target = target
    this.callbacks = callbacks
    this.cipher = new ScreenCastCipher(target.sharedSecret)
    this.captureOptions = qualityOptions(target.quality)
    this.sessionId = util.generateRandomUUID(false)
    this.sequence = 1
    this.queue = []
    this.queuedBytes = 0
    this.sendTail = Promise.resolve()
    this.droppedFrames = 0
    this.sentFrames = 0
    this.sentBytes = 0
    this.statisticsStartedAt = Date.now()
    this.reconnecting = false
    this.mediaReady = false
    this.waitingForKeyFrame = true
    this.latestCodecConfig = undefined
    this.lastMacSequence = -1
    this.lastMacActivityAt = Date.now()
    try {
      await this.connectAndHandshake(false)
      this.publishState('authorizing', '请在系统弹窗中允许屏幕录制')
      const captureResult = this.nativeModule.startCapture(this.captureOptions)
      if (!captureResult.started) throw new Error(captureStartError(captureResult))
      await this.sendVideoConfig()
      this.mediaReady = true
      this.startHeartbeat()
      this.publishState('casting', `正在投屏到 ${target.deviceName}`)
      this.drainQueue().catch((err: Error) => this.reconnect().catch(() => this.fail(err.message)))
    } catch (err) {
      const error = err as Error
      this.fail(error.message || '投屏启动失败')
      throw error
    }
  }

  async stop(reason: string = '用户停止投屏'): Promise<void> {
    if (this.stopped) return
    this.stopped = true
    this.clearHeartbeat()
    this.nativeModule.stopCapture()
    this.queue = []
    this.queuedBytes = 0
    this.mediaReady = false
    const endPayload: CastEndPayload = { reason }
    try { await this.sendControl(CastMessageType.END, encodeCastJson(endPayload)) } catch (_) {}
    const client = this.client
    this.client = undefined
    if (client) await client.close().catch(() => {})
    this.publishState('idle', reason)
  }

  isCasting(): boolean {
    return !this.stopped && this.nativeModule.isCapturing()
  }

  currentState(): CastSenderState { return this.state }
  currentDetail(): string { return this.detail }
  currentFps(): number { return this.fps }
  currentBitrate(): number { return this.bitrate }
  currentDroppedFrames(): number { return this.droppedFrames }

  private async connectAndHandshake(reconnecting: boolean): Promise<void> {
    const target = this.target
    if (!target) throw new Error('缺少投屏目标')
    this.publishState(reconnecting ? 'reconnecting' : 'connecting', reconnecting ? '投屏连接中断，正在恢复' : '正在连接 Mac')
    this.mediaReady = false
    this.lastMacSequence = -1
    this.lastMacActivityAt = Date.now()
    const client = socket.constructTCPSocketInstance()
    const ackPromise = this.waitForAck(client)
    client.on('error', () => {
      if (!this.stopped && this.nativeModule.isCapturing() && this.client === client) {
        this.reconnect().catch((err: Error) => this.fail(err.message))
      }
    })
    client.on('close', () => {
      if (!this.stopped && this.nativeModule.isCapturing() && this.client === client) {
        this.reconnect().catch((err: Error) => this.fail(err.message))
      }
    })
    try {
      await client.connect({ address: { address: target.host, port: target.port }, timeout: 10000 })
      this.client = client
      const hello: CastHello = {
        app: 'HMTrans', protocol: CAST_PROTOCOL_VERSION, deviceId: target.localDeviceId,
        deviceName: target.localDeviceName, identityFingerprint: target.localFingerprint,
        sessionId: this.sessionId, codec: 'h264-annexb', width: this.captureOptions.width,
        height: this.captureOptions.height, frameRate: this.captureOptions.frameRate,
      }
      await client.send({ data: castPacket(CastMessageType.HELLO, CastPacketFlags.NONE, encodeCastJson(hello), 0, 0) })
      const ack = await withTimeout(ackPromise, ACK_TIMEOUT_MS, 'Mac 未响应投屏请求')
      if (!ack.accepted || ack.sessionId !== this.sessionId) throw new Error(ack.reason ?? 'Mac 拒绝了投屏请求')
      // 新连接不等待旧连接遗留的写任务；旧任务持有旧 socket，会自行失败且不会污染本连接。
      this.sendTail = Promise.resolve()
    } catch (err) {
      if (this.client === client) this.client = undefined
      await client.close().catch(() => {})
      const error = err as Error
      throw new Error(error.message || '投屏连接失败')
    }
  }

  private waitForAck(client: socket.TCPSocket): Promise<CastAck> {
    return new Promise<CastAck>((resolve, reject) => {
      let buffer = new ArrayBuffer(0)
      let acknowledged = false
      client.on('error', (err) => {
        if (!acknowledged) reject(new Error(`Mac 投屏连接异常：${errorText(err)}`))
      })
      client.on('close', () => {
        if (!acknowledged) reject(new Error('Mac 已关闭投屏连接'))
      })
      client.on('message', (info: socket.SocketMessageInfo) => {
        buffer = concatBuffers([buffer, info.message])
        try {
          while (buffer.byteLength >= CAST_HEADER_LENGTH) {
            const headerData = buffer.slice(0, CAST_HEADER_LENGTH)
            const header = parseCastHeader(headerData)
            if (header.type === CastMessageType.VIDEO_CONFIG || header.type === CastMessageType.VIDEO_FRAME ||
              header.payloadLength > 64 * 1024 + 28) {
              throw new Error('Mac 返回了无效投屏控制消息')
            }
            const total = CAST_HEADER_LENGTH + header.payloadLength
            if (buffer.byteLength < total) return
            const payload = buffer.slice(CAST_HEADER_LENGTH, total)
            buffer = buffer.slice(total)
            if (header.sequence <= this.lastMacSequence) throw new Error('Mac 返回了重复或乱序的投屏控制消息')
            this.lastMacSequence = header.sequence
            this.lastMacActivityAt = Date.now()
            if (!acknowledged) {
              if (header.type !== CastMessageType.ACK) throw new Error('Mac 返回了无效投屏响应')
              acknowledged = true
              this.decodeAck(header.flags, headerData, payload).then(resolve).catch(reject)
            } else {
              this.handleMacPacket(header.type, header.flags, headerData, payload)
                .catch((err: Error) => this.fail(err.message))
            }
          }
        } catch (err) {
          reject(err as Error)
        }
      })
    })
  }

  /** 接受响应必须由已配对密钥认证；明文只允许携带拒绝原因。 */
  private async decodeAck(flags: number, header: ArrayBuffer, payload: ArrayBuffer): Promise<CastAck> {
    const encrypted = (flags & CastPacketFlags.ENCRYPTED) !== 0
    if (encrypted) {
      if (!this.cipher) throw new Error('投屏配对密钥不可用')
      return decodeCastJson<CastAck>(await this.cipher.decrypt(payload, header))
    }
    const ack = decodeCastJson<CastAck>(payload)
    if (ack.accepted) throw new Error('Mac 返回了未认证的投屏响应')
    return ack
  }

  /** ACK 之后保持读取控制帧，使 Mac 的停止操作可以立即终止系统录屏。 */
  private async handleMacPacket(type: CastMessageType, flags: number, header: ArrayBuffer,
    payload: ArrayBuffer): Promise<void> {
    if ((flags & CastPacketFlags.ENCRYPTED) === 0 || !this.cipher) {
      throw new Error('Mac 返回了未加密的投屏控制消息')
    }
    const plain = await this.cipher.decrypt(payload, header)
    if (type === CastMessageType.STREAM_CONTROL) {
      const control = decodeCastJson<CastStreamControlPayload>(plain)
      if (control.command === 'stop') await this.stop('Mac 已停止投屏')
      return
    }
    if (type === CastMessageType.ERROR || type === CastMessageType.END) {
      await this.stop('Mac 已结束投屏')
    }
  }

  private enqueueFrame(frame: NativeFrame): void {
    if (this.stopped || frame.data.byteLength === 0) return
    const queued: QueuedFrame = { data: frame.data, ptsUs: frame.ptsUs, flags: frame.flags }
    const isKeyFrame = (frame.flags & NATIVE_SYNC_FRAME_FLAG) !== 0
    const isCodecConfig = (frame.flags & NATIVE_CODEC_DATA_FLAG) !== 0
    if (isCodecConfig) this.latestCodecConfig = queued

    // 首次启动和断线恢复都必须从参数集与关键帧开始，不能把不可解码的预测帧送给 Mac。
    if (this.waitingForKeyFrame) {
      if (!isKeyFrame) {
        if (!isCodecConfig) this.droppedFrames += 1
        return
      }
      this.queue = []
      this.queuedBytes = 0
      if (this.latestCodecConfig && this.latestCodecConfig !== queued) this.pushBounded(this.latestCodecConfig)
      this.waitingForKeyFrame = false
    }
    this.pushBounded(queued)
    if (this.mediaReady) {
      this.drainQueue().catch((err: Error) => this.reconnect().catch(() => this.fail(err.message)))
    }
  }

  private pushBounded(frame: QueuedFrame): void {
    while (this.queue.length >= MAX_QUEUED_FRAMES || this.queuedBytes + frame.data.byteLength > MAX_QUEUED_BYTES) {
      const removed = this.queue.shift()
      if (!removed) break
      this.queuedBytes -= removed.data.byteLength
      this.droppedFrames += 1
    }
    this.queue.push(frame)
    this.queuedBytes += frame.data.byteLength
  }

  private async drainQueue(): Promise<void> {
    if (this.sending || this.stopped || !this.mediaReady) return
    this.sending = true
    try {
      while (!this.stopped && this.queue.length > 0) {
        const frame = this.queue.shift()
        if (!frame) break
        this.queuedBytes -= frame.data.byteLength
        let flags = CastPacketFlags.ENCRYPTED
        if ((frame.flags & NATIVE_SYNC_FRAME_FLAG) !== 0) flags |= CastPacketFlags.KEY_FRAME
        if ((frame.flags & NATIVE_CODEC_DATA_FLAG) !== 0) flags |= CastPacketFlags.CODEC_CONFIG
        await this.sendEncrypted(CastMessageType.VIDEO_FRAME, flags, frame.data, frame.ptsUs)
        this.sentFrames += 1
        this.sentBytes += frame.data.byteLength
        this.publishStatistics()
      }
    } finally {
      this.sending = false
    }
  }

  private async sendVideoConfig(): Promise<void> {
    const config: CastVideoConfigPayload = {
      codec: 'h264-annexb',
      width: this.captureOptions.width,
      height: this.captureOptions.height,
      frameRate: this.captureOptions.frameRate,
    }
    await this.sendEncrypted(CastMessageType.VIDEO_CONFIG, CastPacketFlags.ENCRYPTED,
      encodeCastJson(config), 0)
  }

  private async sendControl(type: CastMessageType, plain: ArrayBuffer): Promise<void> {
    await this.sendEncrypted(type, CastPacketFlags.ENCRYPTED, plain, 0)
  }

  private sendEncrypted(type: CastMessageType, flags: number, plain: ArrayBuffer, ptsUs: number): Promise<void> {
    const scheduledClient = this.client
    const cipher = this.cipher
    if (!scheduledClient || !cipher) return Promise.reject(new Error('投屏连接不可用'))

    const operation = this.sendTail.catch(() => {}).then(async () => {
      if (this.client !== scheduledClient) throw new Error('投屏连接已切换')
      const sequence = this.sequence++
      const sealedLength = plain.byteLength + 28
      const header = buildCastHeader(type, flags | CastPacketFlags.ENCRYPTED, sealedLength, sequence, ptsUs)
      const sealed = await cipher.encrypt(plain, header)
      try {
        await scheduledClient.send({ data: concatBuffers([header, sealed]) })
      } catch (err) {
        throw new Error(`投屏数据发送失败：${errorText(err)}`)
      }
    })
    this.sendTail = operation
    return operation
  }

  private startHeartbeat(): void {
    this.clearHeartbeat()
    this.heartbeatTimer = setInterval(() => {
      const heartbeat: CastHeartbeatPayload = { at: Date.now() }
      if (this.stopped) return
      if (Date.now() - this.lastMacActivityAt > CAST_HEARTBEAT_TIMEOUT_MS) {
        this.reconnect().catch((err: Error) => this.fail(err.message))
        return
      }
      this.sendControl(CastMessageType.HEARTBEAT, encodeCastJson(heartbeat))
        .catch(() => this.reconnect().catch((err: Error) => this.fail(err.message)))
    }, CAST_HEARTBEAT_INTERVAL_MS)
  }

  private clearHeartbeat(): void {
    if (this.heartbeatTimer !== undefined) clearInterval(this.heartbeatTimer)
    this.heartbeatTimer = undefined
  }

  private async reconnect(): Promise<void> {
    if (this.stopped || this.reconnecting) return
    this.reconnecting = true
    this.mediaReady = false
    this.waitingForKeyFrame = true
    this.queue = []
    this.queuedBytes = 0
    const deadline = Date.now() + RECONNECT_WINDOW_MS
    const old = this.client
    this.client = undefined
    if (old) await old.close().catch(() => {})
    while (!this.stopped && Date.now() < deadline) {
      try {
        await new Promise<void>((resolve) => setTimeout(resolve, 800))
        await this.connectAndHandshake(true)
        await this.sendVideoConfig()
        this.mediaReady = true
        this.publishState('casting', `已恢复投屏到 ${this.target?.deviceName ?? 'Mac'}`)
        this.reconnecting = false
        this.drainQueue().catch((err: Error) => this.reconnect().catch(() => this.fail(err.message)))
        return
      } catch (_) {}
    }
    this.reconnecting = false
    throw new Error('投屏连接恢复超时')
  }

  private fail(detail: string): void {
    if (this.stopped) return
    this.publishState('failed', detail)
    this.clearHeartbeat()
    this.nativeModule.stopCapture()
    this.queue = []
    this.queuedBytes = 0
    this.mediaReady = false
    this.stopped = true
    const client = this.client
    this.client = undefined
    if (client) client.close().catch(() => {})
  }

  private publishStatistics(): void {
    const elapsed = Math.max(1, Date.now() - this.statisticsStartedAt)
    if (elapsed < 1000) return
    const fps = Math.round(this.sentFrames * 1000 / elapsed)
    const bitrate = Math.round(this.sentBytes * 8 * 1000 / elapsed)
    this.fps = fps
    this.bitrate = bitrate
    this.callbacks?.onStatistics(fps, bitrate, this.droppedFrames)
    this.sentFrames = 0; this.sentBytes = 0; this.statisticsStartedAt = Date.now()
  }

  private publishState(state: CastSenderState, detail: string): void {
    this.state = state
    this.detail = detail
    this.callbacks?.onState(state, detail)
  }
}

function qualityOptions(quality: CastQuality): CaptureOptions {
  if (quality === 'smooth') return { width: 1280, height: 800, frameRate: 24, bitrate: 4 * 1024 * 1024 }
  if (quality === 'quality') return { width: 2560, height: 1600, frameRate: 30, bitrate: 12 * 1024 * 1024 }
  return { width: 1920, height: 1200, frameRate: 30, bitrate: 8 * 1024 * 1024 }
}

function captureStartError(result: NativeCaptureStartResult): string {
  const stage = captureStageName(result.stage)
  const reason = captureErrorName(result.errorCode)
  return `${stage}失败：${reason}（错误码 ${result.errorCode}）`
}

function captureStageName(stage: string): string {
  switch (stage) {
    case 'create': return '创建录屏会话'
    case 'createPickerStrategy': return '创建系统授权界面'
    case 'configurePicker': return '配置系统授权界面'
    case 'configureCallbacks': return '注册录屏回调'
    case 'createEncoder': return '创建 H.264 编码器'
    case 'configureEncoderCallbacks': return '注册 H.264 编码回调'
    case 'createEncoderFormat': return '创建 H.264 编码参数'
    case 'configureEncoder': return '配置 H.264 编码器'
    case 'createEncoderSurface': return '创建 H.264 编码画布'
    case 'prepareEncoder': return '准备 H.264 编码器'
    case 'initialize': return '初始化录屏参数'
    case 'startEncoder': return '启动 H.264 编码器'
    case 'startCaptureSurface': return '启动系统录屏'
    default: return '启动系统录屏'
  }
}

function captureErrorName(errorCode: number): string {
  switch (errorCode) {
    case 1: return '系统内存不足'
    case 2: return '系统不允许当前录屏操作'
    case 3: return '录屏参数无效'
    case 4: return '媒体服务 I/O 异常'
    case 5: return '媒体服务超时'
    case 6: return '媒体服务未知异常'
    case 7: return '媒体服务已退出'
    case 8: return '录屏会话状态无效'
    case 9: return '当前设备不支持该录屏配置'
    default: return '系统返回异常'
  }
}

function withTimeout<T>(promise: Promise<T>, timeoutMs: number, reason: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(reason)), timeoutMs)
    promise.then((value: T) => { clearTimeout(timer); resolve(value) })
      .catch((err: Error) => { clearTimeout(timer); reject(err) })
  })
}
