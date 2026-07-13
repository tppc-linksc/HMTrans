/**
 * 应用发送入口共用的异步并发闸门，避免页面重复操作或自动恢复绕过并发上限。
 */
export class AsyncConcurrencyGate {
  private readonly limit: number
  private active: number = 0
  private waiters: Array<() => void> = []

  constructor(limit: number) {
    if (!Number.isInteger(limit) || limit < 1) throw new Error('并发上限必须是正整数')
    this.limit = limit
  }

  async run<T>(operation: () => Promise<T>): Promise<T> {
    await this.acquire()
    try {
      return await operation()
    } finally {
      this.release()
    }
  }

  private acquire(): Promise<void> {
    if (this.active < this.limit) {
      this.active += 1
      return Promise.resolve()
    }
    return new Promise<void>((resolve) => {
      this.waiters.push(() => {
        this.active += 1
        resolve()
      })
    })
  }

  private release(): void {
    this.active = Math.max(0, this.active - 1)
    const next = this.waiters.shift()
    if (next) next()
  }
}
