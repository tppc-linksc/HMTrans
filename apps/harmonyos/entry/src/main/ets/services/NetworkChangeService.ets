import { connection } from '@kit.NetworkKit'

/**
 * 监听默认网络变化，并把短时间内的多次系统回调合并为一次刷新。
 * 网络切换时发现广播与接收监听都需要重建，否则仍可能绑定旧地址。
 */
export class NetworkChangeService {
  private netConnection?: connection.NetConnection
  private debounceTimer?: number
  private onChanged?: () => void

  start(onChanged: () => void): void {
    if (this.netConnection) return
    this.onChanged = onChanged
    const netConnection = connection.createNetConnection()
    const schedule = (): void => this.scheduleRefresh()
    netConnection.on('netAvailable', schedule)
    netConnection.on('netConnectionPropertiesChange', schedule)
    netConnection.on('netLost', schedule)
    netConnection.on('netUnavailable', schedule)
    this.netConnection = netConnection
    netConnection.register((err?: Error) => {
      if (err) this.stop()
    })
  }

  stop(): void {
    if (this.debounceTimer !== undefined) {
      clearTimeout(this.debounceTimer)
      this.debounceTimer = undefined
    }
    const netConnection = this.netConnection
    this.netConnection = undefined
    this.onChanged = undefined
    if (netConnection) netConnection.unregister(() => {})
  }

  private scheduleRefresh(): void {
    if (this.debounceTimer !== undefined) clearTimeout(this.debounceTimer)
    this.debounceTimer = setTimeout(() => {
      this.debounceTimer = undefined
      this.onChanged?.()
    }, 800)
  }
}
