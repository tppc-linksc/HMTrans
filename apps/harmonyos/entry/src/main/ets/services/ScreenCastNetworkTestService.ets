import { socket } from '@kit.NetworkKit'
import { util } from '@kit.ArkTS'
import { errorText } from '../common/ErrorText'
import { withTimeout } from '../common/AsyncTimeout'
import {
  CAST_HEADER_LENGTH,
  CAST_PROTOCOL_VERSION,
  CastAck,
  CastMessageType,
  CastNetworkTestHello,
  CastNetworkTestPing,
  CastNetworkTestResult,
  CastPacketFlags,
  ScreenCastCipher,
  buildCastHeader,
  castPacket,
  concatBuffers,
  decodeCastJson,
  encodeCastJson,
  parseCastHeader,
} from '../common/ScreenCastProtocol'

const TEST_PAYLOAD_BYTES: number = 32 * 1024 * 1024
const TEST_CHUNK_BYTES: number = 256 * 1024
const TEST_TIMEOUT_MS: number = 45000
const PING_COUNT: number = 10

export interface ScreenCastNetworkTestTarget {
  host: string
  port: number
  deviceId: string
  localDeviceId: string
  localDeviceName: string
  localFingerprint: string
  sharedSecret: string
}

interface ReceivedTestPacket {
  type: CastMessageType
  flags: number
  header: ArrayBuffer
  payload: ArrayBuffer
}

/**
 * 从 Pad 向 Mac 发送内存测试数据。协议复用投屏端口、配对密钥和 AES-GCM，
 * 不访问公网、不写临时文件，测量结果更接近真实投屏链路。
 */
export class ScreenCastNetworkTestService {
  private client?: socket.TCPSocket
  private cipher?: ScreenCastCipher
  private sessionId: string = ''
  private outgoingSequence: number = 1
  private lastIncomingSequence: number = -1
  private receiveBuffer: ArrayBuffer = new ArrayBuffer(0)
  private receiveTail: Promise<void> = Promise.resolve()
  private ackResolve?: (ack: CastAck) => void
  private ackReject?: (err: Error) => void
  private pongResolve?: (ping: CastNetworkTestPing) => void
  private pongReject?: (err: Error) => void
  private resultResolve?: (result: CastNetworkTestResult) => void
  private resultReject?: (err: Error) => void

  async run(target: ScreenCastNetworkTestTarget): Promise<CastNetworkTestResult> {
    const client = socket.constructTCPSocketInstance()
    this.client = client
    this.sessionId = util.generateRandomUUID(false)
    this.cipher = new ScreenCastCipher(target.sharedSecret, this.sessionId, 'screen-cast-network-test-v1')
    this.outgoingSequence = 1
    this.lastIncomingSequence = -1
    this.receiveBuffer = new ArrayBuffer(0)
    client.on('message', (info: socket.SocketMessageInfo) => {
      this.receiveTail = this.receiveTail.then(() => this.consume(info.message)).catch((err: Error) => {
        this.failWaiters(err)
      })
    })
    client.on('error', (err) => this.failWaiters(new Error(errorText(err))))
    client.on('close', () => this.failWaiters(new Error('Mac 已关闭投屏网络测试连接')))

    try {
      await client.connect({ address: { address: target.host, port: target.port }, timeout: 10000 })
      const hello: CastNetworkTestHello = {
        app: 'HMTrans', protocol: CAST_PROTOCOL_VERSION,
        deviceId: target.localDeviceId, deviceName: target.localDeviceName,
        identityFingerprint: target.localFingerprint, sessionId: this.sessionId,
        payloadBytes: TEST_PAYLOAD_BYTES,
      }
      const ackPromise = this.waitForAck()
      await client.send({
        data: castPacket(CastMessageType.NETWORK_TEST_HELLO, CastPacketFlags.NONE,
          encodeCastJson(hello), this.nextSequence(), 0),
      })
      const ack = await withTimeout(ackPromise, TEST_TIMEOUT_MS, 'Mac 未响应投屏网络测试')
      if (!ack.accepted || ack.sessionId !== this.sessionId) {
        throw new Error(ack.reason ?? 'Mac 拒绝了投屏网络测试')
      }

      const rtts: Array<number> = []
      for (let index = 0; index < PING_COUNT; index++) {
        const ping: CastNetworkTestPing = { index, sentAtMs: Date.now() }
        const pongPromise = this.waitForPong()
        await this.sendEncrypted(CastMessageType.NETWORK_TEST_PING, encodeCastJson(ping))
        const pong = await withTimeout(pongPromise, 5000, '投屏网络延迟测试超时')
        if (pong.index !== index) throw new Error('投屏网络测试响应乱序')
        rtts.push(Math.max(0, Date.now() - pong.sentAtMs))
      }

      const serverResultPromise = this.waitForResult()
      const chunk = new ArrayBuffer(TEST_CHUNK_BYTES)
      let sent = 0
      while (sent < TEST_PAYLOAD_BYTES) {
        const size = Math.min(TEST_CHUNK_BYTES, TEST_PAYLOAD_BYTES - sent)
        const payload = size === TEST_CHUNK_BYTES ? chunk : chunk.slice(0, size)
        await this.sendEncrypted(CastMessageType.NETWORK_TEST_DATA, payload)
        sent += size
      }
      const serverResult = await withTimeout(serverResultPromise, TEST_TIMEOUT_MS, 'Mac 未返回投屏网络测试结果')
      const averageRtt = rtts.reduce((sum: number, value: number) => sum + value, 0) / Math.max(1, rtts.length)
      let jitterTotal = 0
      for (let index = 1; index < rtts.length; index++) jitterTotal += Math.abs(rtts[index] - rtts[index - 1])
      const jitter = rtts.length > 1 ? jitterTotal / (rtts.length - 1) : 0
      const result: CastNetworkTestResult = {
        sessionId: this.sessionId,
        receivedBytes: serverResult.receivedBytes,
        durationMs: serverResult.durationMs,
        throughputMbps: serverResult.throughputMbps,
        averageRttMs: averageRtt,
        jitterMs: jitter,
        recommendation: serverResult.recommendation,
      }
      await this.sendEncrypted(CastMessageType.NETWORK_TEST_RESULT, encodeCastJson(result))
      return result
    } catch (err) {
      throw new Error(`投屏网络测试失败：${errorText(err)}`)
    } finally {
      this.client = undefined
      await client.close().catch(() => {})
    }
  }

  private waitForAck(): Promise<CastAck> {
    return new Promise<CastAck>((resolve, reject) => { this.ackResolve = resolve; this.ackReject = reject })
  }

  private waitForPong(): Promise<CastNetworkTestPing> {
    return new Promise<CastNetworkTestPing>((resolve, reject) => {
      this.pongResolve = resolve
      this.pongReject = reject
    })
  }

  private waitForResult(): Promise<CastNetworkTestResult> {
    return new Promise<CastNetworkTestResult>((resolve, reject) => {
      this.resultResolve = resolve
      this.resultReject = reject
    })
  }

  private async consume(data: ArrayBuffer): Promise<void> {
    this.receiveBuffer = concatBuffers([this.receiveBuffer, data])
    while (this.receiveBuffer.byteLength >= CAST_HEADER_LENGTH) {
      const headerData = this.receiveBuffer.slice(0, CAST_HEADER_LENGTH)
      const header = parseCastHeader(headerData)
      const total = CAST_HEADER_LENGTH + header.payloadLength
      if (this.receiveBuffer.byteLength < total) return
      const packet: ReceivedTestPacket = {
        type: header.type,
        flags: header.flags,
        header: headerData,
        payload: this.receiveBuffer.slice(CAST_HEADER_LENGTH, total),
      }
      this.receiveBuffer = this.receiveBuffer.slice(total)
      if (header.sequence <= this.lastIncomingSequence) throw new Error('Mac 返回了重复或乱序测试消息')
      this.lastIncomingSequence = header.sequence
      await this.handle(packet)
    }
  }

  private async handle(packet: ReceivedTestPacket): Promise<void> {
    if (packet.type === CastMessageType.ACK) {
      const encrypted = (packet.flags & CastPacketFlags.ENCRYPTED) !== 0
      const payload = encrypted ? await this.decrypt(packet) : packet.payload
      const ack = decodeCastJson<CastAck>(payload)
      if (ack.accepted && !encrypted) throw new Error('Mac 返回了未认证的测试响应')
      const resolve = this.ackResolve
      this.ackResolve = undefined
      this.ackReject = undefined
      resolve?.(ack)
      return
    }
    if ((packet.flags & CastPacketFlags.ENCRYPTED) === 0) throw new Error('Mac 返回了未加密的测试消息')
    const plain = await this.decrypt(packet)
    if (packet.type === CastMessageType.NETWORK_TEST_PONG) {
      const resolve = this.pongResolve
      this.pongResolve = undefined
      this.pongReject = undefined
      resolve?.(decodeCastJson<CastNetworkTestPing>(plain))
      return
    }
    if (packet.type === CastMessageType.NETWORK_TEST_RESULT) {
      const resolve = this.resultResolve
      this.resultResolve = undefined
      this.resultReject = undefined
      resolve?.(decodeCastJson<CastNetworkTestResult>(plain))
      return
    }
    if (packet.type !== CastMessageType.HEARTBEAT) throw new Error('Mac 返回了无效测试消息')
  }

  private async decrypt(packet: ReceivedTestPacket): Promise<ArrayBuffer> {
    if (!this.cipher) throw new Error('投屏网络测试密钥不可用')
    return this.cipher.decrypt(packet.payload, packet.header)
  }

  private async sendEncrypted(type: CastMessageType, plain: ArrayBuffer): Promise<void> {
    if (!this.client || !this.cipher) throw new Error('投屏网络测试连接不可用')
    const sequence = this.nextSequence()
    const header = buildCastHeader(type, CastPacketFlags.ENCRYPTED, plain.byteLength + 28, sequence, 0)
    const encrypted = await this.cipher.encrypt(plain, header)
    try {
      await this.client.send({ data: concatBuffers([header, encrypted]) })
    } catch (err) {
      throw new Error(`投屏网络测试发送失败：${errorText(err)}`)
    }
  }

  private nextSequence(): number {
    const value = this.outgoingSequence
    this.outgoingSequence += 1
    return value
  }

  private failWaiters(err: Error): void {
    const ackReject = this.ackReject
    const pongReject = this.pongReject
    const resultReject = this.resultReject
    this.ackResolve = undefined; this.ackReject = undefined
    this.pongResolve = undefined; this.pongReject = undefined
    this.resultResolve = undefined; this.resultReject = undefined
    ackReject?.(err); pongReject?.(err); resultReject?.(err)
  }
}
