import { common } from '@kit.AbilityKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { socket } from '@kit.NetworkKit'
import { arrayBufferToString, sliceArrayBuffer } from '../common/Bytes'
import {
  DEFAULT_CHUNK_SIZE,
  DEFAULT_PORT,
  FileMeta,
  ReceiveDecision,
  TransferResult,
  createFileMeta,
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
  onReceived?: (meta: FileMeta, path: string) => void
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

export class TcpTransferService {
  private server?: socket.TCPSocketServer
  private activeConnections: Array<socket.TCPSocketConnection> = []

  async sendFileToMac(
    uri: string,
    host: string,
    port: number,
    callbacks: TransferCallbacks,
    senderDeviceId?: string,
    senderName?: string,
    displayName?: string
  ): Promise<void> {
    const sourceName = displayName ?? fileNameFromUri(uri)
    callbacks.onStatus(`计算校验值：${sourceName}`)
    const size = fileSize(uri)
    const sha256 = await sha256FileAsync(uri)
    const meta = createFileMeta(sourceName, size, sha256, senderDeviceId, senderName, 'HarmonyOS')

    const client = socket.constructTCPSocketInstance()
    const reader = new LineReader()

    try {
      await client.connect({
        address: {
          address: host,
          port,
        },
        timeout: 10000,
      })

      callbacks.onStatus(`已连接 ${host}:${port}`)
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
        return
      }

      const file = fs.openSync(uri, fs.OpenMode.READ_ONLY)
      const buffer = new ArrayBuffer(DEFAULT_CHUNK_SIZE)
      let sent = 0
      try {
        while (true) {
          const count = fs.readSync(file.fd, buffer)
          if (count <= 0) {
            break
          }
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
      await client.close().catch(() => {})
    }
  }

  async startReceiver(context: common.UIAbilityContext, port: number, callbacks: TransferCallbacks, receiveDirectory?: string): Promise<void> {
    if (this.server) {
      callbacks.onStatus('已经在监听')
      return
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
      let targetFile: fs.File | undefined
      let received = 0

      connection.on('message', async (info: socket.SocketMessageInfo) => {
        try {
          if (!meta) {
            const lines = reader.append(info.message)
            if (lines.length === 0) {
              return
            }

            meta = parseJsonLine<FileMeta>(lines[0])
            const accepted = await callbacks.onIncoming(meta)
            await connection.send({ data: encodeJsonLine(createReceiveDecision(accepted, accepted ? undefined : 'user_rejected')) })
            if (!accepted) {
              await this.closeConnection(connection)
              return
            }

            const receiveDir = receiveDirectory && receiveDirectory.length > 0 ? receiveDirectory : `${context.filesDir}/PureSend`
            try {
              fs.mkdirSync(receiveDir)
            } catch (_) {
            }
            targetPath = `${receiveDir}/${meta.fileName}`
            targetPartPath = `${targetPath}.part`
            targetFile = fs.openSync(targetPartPath, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE)
            callbacks.onStatus(`接收中：${meta.fileName}`)
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
              try {
                fs.unlinkSync(targetPath)
              } catch (_) {
              }
              fs.renameSync(targetPartPath, targetPath)
              await connection.send({ data: encodeJsonLine(createTransferResult(meta.transferId, sha256)) })
              callbacks.onStatus(`已保存：${targetPath}`)
              callbacks.onReceived?.(meta, targetPath)
            } else {
              await connection.send({ data: encodeJsonLine(createTransferResult(meta.transferId, sha256, 'hash_mismatch')) })
              callbacks.onStatus('接收失败：SHA-256 不一致')
            }
            await this.closeConnection(connection)
          }
        } catch (err) {
          callbacks.onStatus(`接收错误：${JSON.stringify(err)}`)
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
    await Promise.all(connections.map((connection: socket.TCPSocketConnection) => {
      return connection.close().catch(() => {})
    }))
    await server.close().catch(() => {})
  }
}
