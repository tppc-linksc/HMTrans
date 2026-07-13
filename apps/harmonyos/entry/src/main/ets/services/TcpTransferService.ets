import { common } from '@kit.AbilityKit'
import { fileIo as fs, statfs } from '@kit.CoreFileKit'
import { zlib } from '@kit.BasicServicesKit'
import { socket } from '@kit.NetworkKit'
import { arrayBufferToString, sliceArrayBuffer } from '../common/Bytes'
import {
  DEFAULT_CHUNK_SIZE,
  DEFAULT_PORT,
  APP_NAME,
  PROTOCOL_VERSION,
  FileMeta,
  PairingRequest,
  PairingResponse,
  ReceiveDecision,
  TransferResult,
  createFileMeta,
  createPairingResponse,
  createReceiveDecision,
  createTransferResult,
  encodeJsonLine,
  parseJsonLine,
} from '../common/Protocol'
import { fileNameFromUri } from '../common/Formatters'
import { fileSize, sha256FileAsync } from './FileHashService'
import { errorText } from '../common/ErrorText'
import { ZipSafetyService } from './ZipSafetyService'

const MAX_CONTROL_LINE_CHARS: number = 64 * 1024
const MAX_ACTIVE_CONNECTIONS: number = 16
const CONTROL_RESPONSE_TIMEOUT_MS: number = 30 * 1000
const VERIFY_RESULT_TIMEOUT_MS: number = 10 * 60 * 1000
const RECEIVE_IDLE_TIMEOUT_MS: number = 60 * 1000
const STORAGE_SAFETY_MARGIN_BYTES: number = 64 * 1024 * 1024

export interface TransferCallbacks {
  onStatus: (value: string) => void
  onProgress: (current: number, total: number, meta?: FileMeta) => void
  onIncoming: (meta: FileMeta) => Promise<boolean>
  onPairing: (request: PairingRequest) => Promise<boolean>
  onReceived?: (meta: FileMeta, path: string) => void
  onFailed?: (meta: FileMeta, reason: string) => void
  onInterrupted?: (meta: FileMeta, reason: string) => void
  onTransferActivity?: (active: boolean) => void
}

/** 将发送参数收敛到一个对象，避免调用方因位置参数过多而传错字段。 */
export interface SendFileOptions {
  uri: string
  host: string
  port: number
  callbacks: TransferCallbacks
  senderDeviceId?: string
  senderName?: string
  displayName?: string
  transferId?: string
  sourceKind?: string
  originalSourceName?: string
  sourceSize?: number
  sourceFileCount?: number
  senderFingerprint?: string
}

interface MessageEnvelope {
  type: string
}

class LineReader {
  private buffer: string = ''

  append(data: ArrayBuffer): Array<string> {
    this.buffer += arrayBufferToString(data)
    if (this.buffer.length > MAX_CONTROL_LINE_CHARS && this.buffer.indexOf('\n') < 0) {
      this.buffer = ''
      throw new Error('控制帧超过 64 KiB 上限')
    }
    const lines: Array<string> = []
    while (true) {
      const index = this.buffer.indexOf('\n')
      if (index < 0) {
        break
      }
      if (index > MAX_CONTROL_LINE_CHARS) {
        this.buffer = ''
        throw new Error('控制帧超过 64 KiB 上限')
      }
      lines.push(this.buffer.substring(0, index))
      this.buffer = this.buffer.substring(index + 1)
    }
    return lines
  }
}

/** 为控制响应增加明确上限，避免对端失联后任务永久挂起。 */
function withTimeout<T>(operation: Promise<T>, timeoutMs: number, reason: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(reason)), timeoutMs)
    operation.then((value: T) => {
      clearTimeout(timer)
      resolve(value)
    }).catch((err: Error) => {
      clearTimeout(timer)
      reject(err)
    })
  })
}

class TransferSessionControl {
  private paused: boolean = false
  private cancelled: boolean = false
  private waiters: Array<() => void> = []
  private cancelHandler?: () => void

  pause(): void {
    if (!this.cancelled) {
      this.paused = true
    }
  }

  resume(): void {
    this.paused = false
    this.releaseWaiters()
  }

  cancel(): void {
    this.cancelled = true
    this.paused = false
    this.releaseWaiters()
    this.cancelHandler?.()
  }

  setCancelHandler(handler: () => void): void {
    this.cancelHandler = handler
    if (this.cancelled) {
      handler()
    }
  }

  async checkpoint(): Promise<void> {
    if (this.cancelled) {
      throw new Error('transfer_cancelled')
    }
    if (this.paused) {
      await new Promise<void>((resolve) => {
        this.waiters.push(resolve)
      })
    }
    if (this.cancelled) {
      throw new Error('transfer_cancelled')
    }
  }

  private releaseWaiters(): void {
    const waiters = this.waiters
    this.waiters = []
    waiters.forEach((resolve: () => void) => resolve())
  }
}

function safeReceiveFileName(fileName: string): string {
  const trimmed = fileName.trim()
  const baseName = trimmed.length > 0 ? trimmed : `HMTrans-${Date.now()}`
  return baseName.replace(/[\/\\:\*\?"<>\|]/g, '_')
}

export class TcpTransferService {
  private server?: socket.TCPSocketServer
  private activeConnections: Array<socket.TCPSocketConnection> = []
  private outgoingSessions: Map<string, TransferSessionControl> = new Map()
  private incomingConnections: Map<string, socket.TCPSocketConnection> = new Map()
  private pausedIncomingTransferIDs: Set<string> = new Set()
  private cancelledIncomingTransferIDs: Set<string> = new Set()
  private zipSafetyService: ZipSafetyService = new ZipSafetyService()

  pauseTransfer(transferId: string): void {
    this.outgoingSessions.get(transferId)?.pause()
    const incoming = this.incomingConnections.get(transferId)
    if (incoming) {
      this.pausedIncomingTransferIDs.add(transferId)
      incoming.close().catch(() => {})
    }
  }

  resumeTransfer(transferId: string): void {
    this.outgoingSessions.get(transferId)?.resume()
    this.pausedIncomingTransferIDs.delete(transferId)
    this.cancelledIncomingTransferIDs.delete(transferId)
  }

  cancelTransfer(transferId: string): void {
    this.outgoingSessions.get(transferId)?.cancel()
    this.cancelledIncomingTransferIDs.add(transferId)
    this.pausedIncomingTransferIDs.delete(transferId)
    const incoming = this.incomingConnections.get(transferId)
    if (incoming) {
      this.incomingConnections.delete(transferId)
      incoming.close().catch(() => {})
    }
  }

  /** 等待已取消任务的文件句柄与套接字退出 finally 清理段。 */
  async waitForIdle(timeoutMs: number = 3000): Promise<boolean> {
    const deadline = Date.now() + timeoutMs
    while (Date.now() < deadline) {
      if (this.outgoingSessions.size === 0 && this.incomingConnections.size === 0) return true
      await new Promise<void>((resolve) => setTimeout(resolve, 50))
    }
    return this.outgoingSessions.size === 0 && this.incomingConnections.size === 0
  }

  async requestPairing(host: string, port: number, request: PairingRequest): Promise<PairingResponse> {
    const client = socket.constructTCPSocketInstance()
    const reader = new LineReader()
    try {
      await client.connect({ address: { address: host, port }, timeout: 10000 })
      await client.send({ data: encodeJsonLine(request) })
      return await withTimeout(new Promise<PairingResponse>((resolve, reject) => {
        client.on('message', (info: socket.SocketMessageInfo) => {
          try {
            const lines = reader.append(info.message)
            if (lines.length > 0) resolve(parseJsonLine<PairingResponse>(lines[0]))
          } catch (err) {
            reject(new Error(errorText(err)))
          }
        })
        client.on('error', (err) => reject(err))
      }), CONTROL_RESPONSE_TIMEOUT_MS, 'pairing_response_timeout')
    } finally {
      await client.close().catch(() => {})
    }
  }

  async sendFileToMac(options: SendFileOptions): Promise<void> {
    const uri = options.uri
    const host = options.host
    const port = options.port
    const callbacks = options.callbacks
    const senderDeviceId = options.senderDeviceId
    const senderName = options.senderName
    const displayName = options.displayName
    const transferId = options.transferId
    const sourceKind = options.sourceKind
    const originalSourceName = options.originalSourceName
    const sourceSize = options.sourceSize
    const sourceFileCount = options.sourceFileCount
    const senderFingerprint = options.senderFingerprint
    callbacks.onTransferActivity?.(true)
    const payloadName = displayName ?? fileNameFromUri(uri)
    callbacks.onStatus(`计算校验值：${payloadName}`)
    const size = fileSize(uri)
    const sha256 = await sha256FileAsync(uri)
    const meta = createFileMeta(payloadName, size, sha256, senderDeviceId, senderName, 'HarmonyOS', transferId,
      sourceKind, originalSourceName, sourceSize, sourceFileCount, senderFingerprint)

    const client = socket.constructTCPSocketInstance()
    const reader = new LineReader()
    const control = new TransferSessionControl()
    this.outgoingSessions.set(meta.transferId, control)
    control.setCancelHandler(() => {
      client.close().catch(() => {})
    })

    try {
      await control.checkpoint()
      await client.connect({
        address: {
          address: host,
          port,
        },
        timeout: 10000,
      })

      callbacks.onStatus(`已连接 ${host}:${port}`)
      await control.checkpoint()
      await client.send({ data: encodeJsonLine(meta) })

      const decision = await withTimeout(new Promise<ReceiveDecision>((resolve, reject) => {
        client.on('message', (info: socket.SocketMessageInfo) => {
          try {
            const lines = reader.append(info.message)
            if (lines.length > 0) resolve(parseJsonLine<ReceiveDecision>(lines[0]))
          } catch (err) {
            reject(new Error(errorText(err)))
          }
        })
        client.on('error', (err) => reject(err))
      }), CONTROL_RESPONSE_TIMEOUT_MS, 'receive_decision_timeout')

      if (!decision.accepted) {
        callbacks.onStatus(`接收方拒绝：${decision.reason ?? '无原因'}`)
        throw new Error(`接收方拒绝：${decision.reason ?? '无原因'}`)
      }

      const resumeOffset = decision.resumeOffset ?? 0
      if (resumeOffset < 0 || resumeOffset > size) {
        throw new Error(`接收方返回了无效断点：${resumeOffset}/${size}`)
      }
      callbacks.onProgress(resumeOffset, size)

      const file = fs.openSync(uri, fs.OpenMode.READ_ONLY)
      const buffer = new ArrayBuffer(DEFAULT_CHUNK_SIZE)
      let sent = resumeOffset
      try {
        if (resumeOffset > 0) {
          fs.lseek(file.fd, resumeOffset, fs.WhenceType.SEEK_SET)
        }
        while (true) {
          await control.checkpoint()
          const count = fs.readSync(file.fd, buffer)
          if (count <= 0) {
            break
          }
          await control.checkpoint()
          await client.send({ data: sliceArrayBuffer(buffer, count) })
          sent += count
          callbacks.onProgress(sent, size)
        }
      } finally {
        try {
          fs.closeSync(file)
        } catch (_) {
        }
      }

      const result = await withTimeout(new Promise<TransferResult>((resolve, reject) => {
        client.off('message')
        client.on('message', (info: socket.SocketMessageInfo) => {
          try {
            const lines = reader.append(info.message)
            if (lines.length > 0) resolve(parseJsonLine<TransferResult>(lines[0]))
          } catch (err) {
            reject(new Error(errorText(err)))
          }
        })
        client.on('error', (err) => reject(err))
      }), VERIFY_RESULT_TIMEOUT_MS, 'transfer_verify_timeout')

      if (result.type !== 'transfer_success') {
        throw new Error(`接收方报告失败：${result.reason ?? 'unknown'}`)
      }
      callbacks.onStatus('发送完成，Mac 校验通过')
    } catch (err) {
      callbacks.onStatus(`发送错误：${errorText(err)}`)
      throw new Error(errorText(err))
    } finally {
      this.outgoingSessions.delete(meta.transferId)
      await client.close().catch(() => {})
      callbacks.onTransferActivity?.(false)
    }
  }

  async startReceiver(context: common.UIAbilityContext, port: number, callbacks: TransferCallbacks, receiveDirectory?: string): Promise<void> {
    if (this.server) {
      callbacks.onStatus('已经在监听')
      return
    }
    if (!receiveDirectory || receiveDirectory.length === 0) {
      throw new Error('下载目录未就绪，无法启动接收服务')
    }

    const server = socket.constructTCPSocketServerInstance()

    server.on('error', (err) => {
      callbacks.onStatus(`接收服务错误：${errorText(err)}`)
      this.closeReceiver(server).catch(() => {})
    })

    server.on('connect', async (connection: socket.TCPSocketConnection) => {
      if (this.activeConnections.length >= MAX_ACTIVE_CONNECTIONS) {
        callbacks.onStatus('接收连接过多，已拒绝新的局域网连接')
        await connection.close().catch(() => {})
        return
      }
      this.activeConnections.push(connection)
      const reader = new LineReader()
      let meta: FileMeta | undefined
      let targetPath = ''
      let targetPartPath = ''
      let targetMetaPath = ''
      let targetFile: fs.File | undefined
      let received = 0
      let activityStarted = false
      let connectionFinished = false
      let idleTimer: number | undefined

      /** 所有退出路径共用一个幂等清理入口，避免重复关闭文件、套接字和后台活动。 */
      const finishConnection = async (): Promise<void> => {
        if (connectionFinished) return
        connectionFinished = true
        if (idleTimer !== undefined) {
          clearTimeout(idleTimer)
          idleTimer = undefined
        }
        if (targetFile) {
          try { fs.closeSync(targetFile) } catch (_) {}
          targetFile = undefined
        }
        if (meta) this.incomingConnections.delete(meta.transferId)
        if (activityStarted) {
          callbacks.onTransferActivity?.(false)
          activityStarted = false
        }
        await this.closeConnection(connection)
      }

      /** 静默对端也必须释放资源；中断保留私有分片，供相同任务 ID 续传。 */
      const interruptConnection = async (reason: string): Promise<void> => {
        if (connectionFinished) return
        if (meta && !this.pausedIncomingTransferIDs.has(meta.transferId) &&
          !this.cancelledIncomingTransferIDs.has(meta.transferId)) {
          callbacks.onInterrupted?.(meta, reason)
          callbacks.onStatus(`接收中断，已保留断点：${meta.fileName}`)
        }
        await finishConnection()
      }

      const resetIdleTimer = (): void => {
        if (idleTimer !== undefined) clearTimeout(idleTimer)
        idleTimer = setTimeout(() => {
          interruptConnection('receive_idle_timeout').catch(() => {})
        }, RECEIVE_IDLE_TIMEOUT_MS)
      }
      resetIdleTimer()

      /** 完成统一的校验、发布和回执流程，零字节文件也会走到这里。 */
      const finalizeIncoming = async (): Promise<void> => {
        if (!meta || !targetFile || received < meta.fileSize) return
        const finalMeta = meta
        fs.closeSync(targetFile)
        targetFile = undefined
        const sha256 = await sha256FileAsync(targetPartPath)
        if (sha256 === finalMeta.sha256) {
          const publishedPath = await this.publishReceivedPayload(
            context,
            finalMeta,
            targetPartPath,
            receiveDirectory,
            `${context.filesDir}/HMTrans/Staging`
          )
          try {
            fs.unlinkSync(targetMetaPath)
          } catch (_) {
          }
          if (finalMeta.sourceKind === 'folder' || fs.statSync(publishedPath).size === finalMeta.fileSize) {
            await connection.send({ data: encodeJsonLine(createTransferResult(finalMeta.transferId, sha256)) })
            callbacks.onStatus(`已保存：${publishedPath}`)
            callbacks.onReceived?.(finalMeta, publishedPath)
          } else {
            const savedSize = fs.statSync(publishedPath).size
            const reason = `saved_size_mismatch:${savedSize}/${finalMeta.fileSize}`
            await connection.send({ data: encodeJsonLine(createTransferResult(finalMeta.transferId, sha256, reason)) })
            callbacks.onStatus(`接收失败：文件保存校验失败 ${reason}`)
            callbacks.onFailed?.(finalMeta, reason)
          }
        } else {
          try {
            fs.unlinkSync(targetPartPath)
          } catch (_) {
          }
          try {
            fs.unlinkSync(targetMetaPath)
          } catch (_) {
          }
          await connection.send({
            data: encodeJsonLine(createTransferResult(finalMeta.transferId, sha256, 'hash_mismatch')),
          })
          callbacks.onStatus('接收失败：SHA-256 不一致')
          callbacks.onFailed?.(finalMeta, 'hash_mismatch')
        }
        await finishConnection()
      }

      connection.on('message', async (info: socket.SocketMessageInfo) => {
        if (connectionFinished) return
        resetIdleTimer()
        try {
          if (!meta) {
            const lines = reader.append(info.message)
            if (lines.length === 0) {
              return
            }

            const envelope = parseJsonLine<MessageEnvelope>(lines[0])
            if (envelope.type === 'pairing_request') {
              const request = parseJsonLine<PairingRequest>(lines[0])
              const compatible = request.app === APP_NAME && request.version === PROTOCOL_VERSION &&
                request.requesterDeviceId.length > 0 && request.requesterFingerprint !== undefined &&
                request.requesterFingerprint.length > 0
              const accepted = compatible && await callbacks.onPairing(request)
              const reason = accepted ? undefined : compatible ? 'invalid_pairing_code' : 'protocol_incompatible'
              await connection.send({ data: encodeJsonLine(createPairingResponse(accepted, reason)) })
              await finishConnection()
              return
            }

            meta = parseJsonLine<FileMeta>(lines[0])
            if (meta.type !== 'file_meta' || meta.app !== APP_NAME || meta.version !== PROTOCOL_VERSION ||
              meta.transferId.length === 0 || !Number.isSafeInteger(meta.fileSize) || meta.fileSize < 0 ||
              !Number.isSafeInteger(meta.chunkSize) || meta.chunkSize <= 0 ||
              !Number.isSafeInteger(meta.totalChunks) || meta.totalChunks < 0 || meta.sha256.length !== 64) {
              await connection.send({ data: encodeJsonLine(createReceiveDecision(false, 'invalid_meta')) })
              await finishConnection()
              return
            }
            if (this.pausedIncomingTransferIDs.has(meta.transferId) ||
              this.cancelledIncomingTransferIDs.has(meta.transferId)) {
              const reason = this.pausedIncomingTransferIDs.has(meta.transferId) ? 'receiver_paused' : 'receiver_cancelled'
              await connection.send({ data: encodeJsonLine(createReceiveDecision(false, reason)) })
              await finishConnection()
              return
            }
            const accepted = await callbacks.onIncoming(meta)
            if (!accepted) {
              await connection.send({ data: encodeJsonLine(createReceiveDecision(false, 'user_rejected')) })
              await finishConnection()
              return
            }

            const receiveDir = receiveDirectory
            const stagingDir = `${context.filesDir}/HMTrans/Staging`
            try {
              fs.mkdirSync(receiveDir)
            } catch (_) {
            }
            try {
              fs.mkdirSync(stagingDir)
            } catch (_) {
            }
            const safeName = safeReceiveFileName(meta.fileName)
            targetPath = `${receiveDir}/${safeName}`
            targetPartPath = `${stagingDir}/${safeReceiveFileName(meta.transferId)}.part`
            targetMetaPath = `${stagingDir}/${safeReceiveFileName(meta.transferId)}.meta.json`
            let resumeOffset = 0
            if (meta.resumeSupported === true) {
              try {
                const savedMeta = JSON.parse(fs.readTextSync(targetMetaPath)) as FileMeta
                const partSize = fs.statSync(targetPartPath).size
                if (savedMeta.sha256 === meta.sha256 && savedMeta.fileSize === meta.fileSize &&
                  savedMeta.fileName === meta.fileName && partSize >= 0 && partSize <= meta.fileSize) {
                  resumeOffset = partSize
                }
              } catch (_) {
                resumeOffset = 0
              }
            }
            if (resumeOffset === 0) {
              try {
                fs.unlinkSync(targetPartPath)
              } catch (_) {
              }
              try {
                fs.unlinkSync(targetMetaPath)
              } catch (_) {
              }
            }
            const remainingBytes = meta.fileSize - resumeOffset
            const availableBytes = statfs.getFreeSizeSync(stagingDir)
            if (availableBytes < remainingBytes + STORAGE_SAFETY_MARGIN_BYTES) {
              await connection.send({ data: encodeJsonLine(createReceiveDecision(false, 'insufficient_space')) })
              callbacks.onStatus('接收失败：存储空间不足，请清理空间后继续')
              callbacks.onFailed?.(meta, 'insufficient_space')
              await finishConnection()
              return
            }
            const metaFile = fs.openSync(targetMetaPath, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE)
            try {
              fs.writeSync(metaFile.fd, JSON.stringify(meta))
            } finally {
              fs.closeSync(metaFile)
            }
            targetFile = fs.openSync(targetPartPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE)
            if (resumeOffset > 0) {
              fs.lseek(targetFile.fd, resumeOffset, fs.WhenceType.SEEK_SET)
            }
            received = resumeOffset
            this.incomingConnections.set(meta.transferId, connection)
            callbacks.onTransferActivity?.(true)
            activityStarted = true
            await connection.send({ data: encodeJsonLine(createReceiveDecision(true, undefined, resumeOffset)) })
            callbacks.onProgress(received, meta.fileSize, meta)
            callbacks.onStatus(`接收中：${safeName}`)
            await finalizeIncoming()
            return
          }

          if (!targetFile || !meta) {
            return
          }

          fs.writeSync(targetFile.fd, info.message)
          received += info.message.byteLength
          callbacks.onProgress(received, meta.fileSize, meta)

          await finalizeIncoming()
        } catch (err) {
          const errorDetail = errorText(err)
          const storageFull = errorDetail.indexOf('ENOSPC') >= 0 || errorDetail.indexOf('No space') >= 0 ||
            errorDetail.indexOf('errno:28') >= 0 || errorDetail.indexOf('code:28') >= 0
          const failureReason = storageFull ? 'insufficient_space' : `receive_exception:${errorDetail}`
          callbacks.onStatus(storageFull ? '接收失败：存储空间不足，请清理空间后继续' : `接收错误：${errorDetail}`)
          if (meta) {
            await connection.send({
              data: encodeJsonLine(createTransferResult(meta.transferId, null, failureReason)),
            }).catch(() => {})
            callbacks.onFailed?.(meta, failureReason)
          }
          await finishConnection()
        }
      })
      connection.on('close', () => {
        interruptConnection('connection_closed').catch(() => {})
      })
      connection.on('error', (err) => {
        interruptConnection(`connection_error:${errorText(err)}`).catch(() => {})
      })
    })

    try {
      await server.listen({
        address: '0.0.0.0',
        port: port || DEFAULT_PORT,
      })
      this.server = server
      callbacks.onStatus(`监听端口 ${port || DEFAULT_PORT}`)
    } catch (err) {
      this.server = undefined
      await server.close().catch(() => {})
      throw new Error(errorText(err))
    }
  }

  async stopReceive(): Promise<void> {
    if (!this.server) {
      return
    }
    const server = this.server
    await this.closeReceiver(server)
  }

  private async closeConnection(connection: socket.TCPSocketConnection): Promise<void> {
    this.activeConnections = this.activeConnections.filter((item: socket.TCPSocketConnection) => item !== connection)
    await connection.close().catch(() => {})
  }

  private async closeReceiver(server: socket.TCPSocketServer): Promise<void> {
    if (this.server === server) {
      this.server = undefined
    }
    const connections = this.activeConnections
    this.activeConnections = []
    this.incomingConnections.clear()
    await Promise.all(connections.map((connection: socket.TCPSocketConnection) => {
      return connection.close().catch(() => {})
    }))
    await server.close().catch(() => {})
  }

  /** 在私有目录解压已校验的文件夹，最后只发布一个完整目录。 */
  private async publishReceivedPayload(context: common.UIAbilityContext, meta: FileMeta, payloadPath: string,
    receiveDirectory: string, stagingDir: string): Promise<string> {
    if (meta.sourceKind !== 'folder' || meta.payloadKind !== 'zip') {
      const destination = this.availableDestination(receiveDirectory, safeReceiveFileName(meta.fileName))
      fs.renameSync(payloadPath, destination)
      return destination
    }

    const validation = this.zipSafetyService.validate(payloadPath)
    const availableBytes = statfs.getFreeSizeSync(stagingDir)
    if (availableBytes < validation.expandedSize + STORAGE_SAFETY_MARGIN_BYTES) {
      throw new Error('insufficient_space_for_archive_expansion')
    }
    const unpackRoot = `${stagingDir}/${safeReceiveFileName(meta.transferId)}-unpack`
    try {
      fs.rmdirSync(unpackRoot)
    } catch (_) {
    }
    await zlib.decompressFile(payloadPath, unpackRoot)
    const sourceName = safeReceiveFileName(meta.sourceName ?? '接收的文件夹')
    const destination = this.availableDestination(receiveDirectory, sourceName)
    const children = fs.listFileSync(unpackRoot).filter((name: string) => name !== '__MACOSX')
    if (children.length === 1) {
      const childPath = `${unpackRoot}/${children[0]}`
      if (fs.statSync(childPath).isDirectory()) {
        fs.renameSync(childPath, destination)
        try {
          fs.rmdirSync(unpackRoot)
        } catch (_) {
        }
      } else {
        fs.renameSync(unpackRoot, destination)
      }
    } else {
      fs.renameSync(unpackRoot, destination)
    }
    fs.unlinkSync(payloadPath)
    return destination
  }

  private availableDestination(directory: string, fileName: string): string {
    let candidate = `${directory}/${fileName}`
    const dotIndex = fileName.lastIndexOf('.')
    const hasExtension = dotIndex > 0 && dotIndex < fileName.length - 1
    const stem = hasExtension ? fileName.substring(0, dotIndex) : fileName
    const extension = hasExtension ? fileName.substring(dotIndex) : ''
    let index = 1
    while (true) {
      try {
        fs.statSync(candidate)
        candidate = `${directory}/${stem}-${index}${extension}`
        index += 1
      } catch (_) {
        return candidate
      }
    }
  }
}
