import { common } from '@kit.AbilityKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { zlib } from '@kit.BasicServicesKit'
import { socket } from '@kit.NetworkKit'
import { arrayBufferToString, sliceArrayBuffer } from '../common/Bytes'
import {
  DEFAULT_CHUNK_SIZE,
  DEFAULT_PORT,
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
import { fileNameFromUri, fileSize, sha256FileAsync } from './FileHashService'

export interface TransferCallbacks {
  onStatus: (value: string) => void
  onProgress: (current: number, total: number, meta?: FileMeta) => void
  onIncoming: (meta: FileMeta) => Promise<boolean>
  onPairing: (request: PairingRequest) => Promise<boolean>
  onReceived?: (meta: FileMeta, path: string) => void
  onFailed?: (meta: FileMeta, reason: string) => void
  onTransferActivity?: (active: boolean) => void
}

interface MessageEnvelope {
  type: string
}

class LineReader {
  private buffer: string = ''

  append(data: ArrayBuffer): Array<string> {
    this.buffer += arrayBufferToString(data)
    const lines: Array<string> = []
    while (true) {
      const index = this.buffer.indexOf('\n')
      if (index < 0) {
        break
      }
      lines.push(this.buffer.substring(0, index))
      this.buffer = this.buffer.substring(index + 1)
    }
    return lines
  }
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

  async requestPairing(host: string, port: number, request: PairingRequest): Promise<PairingResponse> {
    const client = socket.constructTCPSocketInstance()
    const reader = new LineReader()
    try {
      await client.connect({ address: { address: host, port }, timeout: 10000 })
      await client.send({ data: encodeJsonLine(request) })
      return await new Promise<PairingResponse>((resolve, reject) => {
        client.on('message', (info: socket.SocketMessageInfo) => {
          const lines = reader.append(info.message)
          if (lines.length > 0) {
            resolve(parseJsonLine<PairingResponse>(lines[0]))
          }
        })
        client.on('error', (err) => reject(err))
      })
    } finally {
      await client.close().catch(() => {})
    }
  }

  async sendFileToMac(
    uri: string,
    host: string,
    port: number,
    callbacks: TransferCallbacks,
    senderDeviceId?: string,
    senderName?: string,
    displayName?: string,
    transferId?: string,
    sourceKind?: string,
    originalSourceName?: string,
    sourceSize?: number,
    sourceFileCount?: number,
    senderFingerprint?: string
  ): Promise<void> {
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

      const decision = await new Promise<ReceiveDecision>((resolve, reject) => {
        client.on('message', (info: socket.SocketMessageInfo) => {
          const lines = reader.append(info.message)
          if (lines.length > 0) {
            resolve(parseJsonLine<ReceiveDecision>(lines[0]))
          }
        })
        client.on('error', (err) => reject(err))
      })

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

      const result = await new Promise<TransferResult>((resolve, reject) => {
        client.off('message')
        client.on('message', (info: socket.SocketMessageInfo) => {
          const lines = reader.append(info.message)
          if (lines.length > 0) {
            resolve(parseJsonLine<TransferResult>(lines[0]))
          }
        })
        client.on('error', (err) => reject(err))
      })

      if (result.type !== 'transfer_success') {
        throw new Error(`接收方报告失败：${result.reason ?? 'unknown'}`)
      }
      callbacks.onStatus('发送完成，Mac 校验通过')
    } catch (err) {
      callbacks.onStatus(`发送错误：${JSON.stringify(err)}`)
      throw new Error(JSON.stringify(err))
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
      callbacks.onStatus(`接收服务错误：${JSON.stringify(err)}`)
      this.closeReceiver(server).catch(() => {})
    })

    server.on('connect', async (connection: socket.TCPSocketConnection) => {
      this.activeConnections.push(connection)
      const reader = new LineReader()
      let meta: FileMeta | undefined
      let targetPath = ''
      let targetPartPath = ''
      let targetMetaPath = ''
      let targetFile: fs.File | undefined
      let received = 0
      let activityStarted = false

      connection.on('message', async (info: socket.SocketMessageInfo) => {
        try {
          if (!meta) {
            const lines = reader.append(info.message)
            if (lines.length === 0) {
              return
            }

            const envelope = parseJsonLine<MessageEnvelope>(lines[0])
            if (envelope.type === 'pairing_request') {
              const request = parseJsonLine<PairingRequest>(lines[0])
              const accepted = await callbacks.onPairing(request)
              await connection.send({ data: encodeJsonLine(createPairingResponse(accepted, accepted ? undefined : 'invalid_pairing_code')) })
              await this.closeConnection(connection)
              return
            }

            meta = parseJsonLine<FileMeta>(lines[0])
            if (this.pausedIncomingTransferIDs.has(meta.transferId) ||
              this.cancelledIncomingTransferIDs.has(meta.transferId)) {
              const reason = this.pausedIncomingTransferIDs.has(meta.transferId) ? 'receiver_paused' : 'receiver_cancelled'
              await connection.send({ data: encodeJsonLine(createReceiveDecision(false, reason)) })
              await this.closeConnection(connection)
              return
            }
            const accepted = await callbacks.onIncoming(meta)
            if (!accepted) {
              await connection.send({ data: encodeJsonLine(createReceiveDecision(false, 'user_rejected')) })
              await this.closeConnection(connection)
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
            return
          }

          if (!targetFile || !meta) {
            return
          }

          fs.writeSync(targetFile.fd, info.message)
          received += info.message.byteLength
          callbacks.onProgress(received, meta.fileSize, meta)

          if (received >= meta.fileSize) {
            fs.closeSync(targetFile)
            targetFile = undefined
            const sha256 = await sha256FileAsync(targetPartPath)
            if (sha256 === meta.sha256) {
              const publishedPath = await this.publishReceivedPayload(
                context,
                meta,
                targetPartPath,
                receiveDirectory,
                `${context.filesDir}/HMTrans/Staging`
              )
              try {
                fs.unlinkSync(targetMetaPath)
              } catch (_) {
              }
              if (meta.sourceKind === 'folder' || fs.statSync(publishedPath).size === meta.fileSize) {
                await connection.send({ data: encodeJsonLine(createTransferResult(meta.transferId, sha256)) })
                callbacks.onStatus(`已保存：${publishedPath}`)
                callbacks.onReceived?.(meta, publishedPath)
              } else {
                const savedSize = fs.statSync(publishedPath).size
                const reason = `saved_size_mismatch:${savedSize}/${meta.fileSize}`
                await connection.send({ data: encodeJsonLine(createTransferResult(meta.transferId, sha256, reason)) })
                callbacks.onStatus(`接收失败：文件保存校验失败 ${reason}`)
                callbacks.onFailed?.(meta, reason)
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
              await connection.send({ data: encodeJsonLine(createTransferResult(meta.transferId, sha256, 'hash_mismatch')) })
              callbacks.onStatus('接收失败：SHA-256 不一致')
              callbacks.onFailed?.(meta, 'hash_mismatch')
            }
            await this.closeConnection(connection)
            this.incomingConnections.delete(meta.transferId)
            if (activityStarted) {
              callbacks.onTransferActivity?.(false)
              activityStarted = false
            }
          }
        } catch (err) {
          const errorDetail = JSON.stringify(err)
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
          if (targetFile) {
            try {
              fs.closeSync(targetFile)
            } catch (_) {
            }
            targetFile = undefined
          }
          await this.closeConnection(connection)
          if (meta) {
            this.incomingConnections.delete(meta.transferId)
          }
          if (activityStarted) {
            callbacks.onTransferActivity?.(false)
            activityStarted = false
          }
        }
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
      throw new Error(JSON.stringify(err))
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

  /** Extracts verified folders privately, then publishes one final directory. */
  private async publishReceivedPayload(context: common.UIAbilityContext, meta: FileMeta, payloadPath: string,
    receiveDirectory: string, stagingDir: string): Promise<string> {
    if (meta.sourceKind !== 'folder' || meta.payloadKind !== 'zip') {
      const destination = this.availableDestination(receiveDirectory, safeReceiveFileName(meta.fileName))
      fs.renameSync(payloadPath, destination)
      return destination
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
    let index = 1
    while (true) {
      try {
        fs.statSync(candidate)
        candidate = `${directory}/${fileName}-${index}`
        index += 1
      } catch (_) {
        return candidate
      }
    }
  }
}
