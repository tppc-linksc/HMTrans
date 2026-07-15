import { arrayBufferToString } from '../common/Bytes'

const MAX_CONTROL_LINE_CHARS: number = 64 * 1024
const MAX_QUEUED_CONTROL_LINES: number = 8

interface PendingLine {
  resolve: (line: string) => void
  reject: (error: Error) => void
}

/**
 * 在一条 TCP 连接上持续接收换行分隔的控制帧。
 *
 * 发送流程会依次等待接收决定和最终校验结果。这里保留提前到达的帧，避免在更换
 * message 监听器的空窗期丢失最终结果，尤其是很小的文件几乎会立即完成。
 */
export class ControlLineInbox {
  private buffer: string = ''
  private lines: Array<string> = []
  private waiters: Array<PendingLine> = []
  private terminalError?: Error

  append(data: ArrayBuffer): void {
    if (this.terminalError) return
    try {
      this.buffer += arrayBufferToString(data)
      if (this.buffer.length > MAX_CONTROL_LINE_CHARS && this.buffer.indexOf('\n') < 0) {
        throw new Error('控制帧超过 64 KiB 上限')
      }
      while (true) {
        const index = this.buffer.indexOf('\n')
        if (index < 0) break
        if (index > MAX_CONTROL_LINE_CHARS) throw new Error('控制帧超过 64 KiB 上限')
        const line = this.buffer.substring(0, index)
        this.buffer = this.buffer.substring(index + 1)
        this.deliver(line)
      }
      if (this.buffer.length > MAX_CONTROL_LINE_CHARS) {
        throw new Error('控制帧超过 64 KiB 上限')
      }
    } catch (err) {
      this.fail(err instanceof Error ? err : new Error(String(err)))
    }
  }

  nextLine(): Promise<string> {
    if (this.lines.length > 0) {
      return Promise.resolve(this.lines.shift() as string)
    }
    if (this.terminalError) return Promise.reject(this.terminalError)
    return new Promise<string>((resolve, reject) => {
      this.waiters.push({ resolve, reject })
    })
  }

  fail(error: Error): void {
    if (this.terminalError) return
    this.terminalError = error
    const waiters = this.waiters
    this.waiters = []
    waiters.forEach((waiter: PendingLine) => waiter.reject(error))
  }

  private deliver(line: string): void {
    const waiter = this.waiters.shift()
    if (waiter) waiter.resolve(line)
    else if (this.lines.length < MAX_QUEUED_CONTROL_LINES) this.lines.push(line)
    else this.fail(new Error('待处理控制帧数量超过上限'))
  }
}
