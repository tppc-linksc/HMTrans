import { socket } from '@kit.NetworkKit'
import { arrayBufferToString } from '../common/Bytes'
import { DISCOVERY_PORT, DeviceInfo, createDeviceInfo } from '../common/Protocol'
import { errorText } from '../common/ErrorText'

export interface DiscoveryCallbacks {
  onDevice: (device: DeviceInfo) => void
  onStatus: (value: string) => void
}

/**
 * 发现链路的收发计数。
 * 只用于本地体检：「已发出但一条都没收到」是区分「对端没发」和「本机收不到」的关键证据。
 */
export interface DiscoveryStats {
  sentBeacons: number
  failedBeacons: number
  receivedPackets: number
  lastSentAt: number
  lastReceivedAt: number
  lastError: string
}

export class DiscoveryService {
  private udp?: socket.UDPSocket
  private timer?: number
  private deviceId: string
  private discoveryPort: number = DISCOVERY_PORT
  private identityFingerprint: string
  private directedReplyAt: Map<string, number> = new Map()
  private shouldAcknowledge: (device: DeviceInfo) => boolean
  private beaconDeviceName: string = ''
  private beaconTransferPort: number = 0
  private beaconScreenCastPort: number = 0
  private beaconLocalIp: string = ''
  private beaconNetworkName: string = ''
  private beaconSystemVersion: string = ''
  private sentBeacons: number = 0
  private failedBeacons: number = 0
  private receivedPackets: number = 0
  private lastSentAt: number = 0
  private lastReceivedAt: number = 0
  private lastErrorText: string = ''

  constructor(deviceId: string, identityFingerprint: string,
    shouldAcknowledge: (device: DeviceInfo) => boolean = (_device: DeviceInfo): boolean => true) {
    this.deviceId = deviceId
    this.identityFingerprint = identityFingerprint
    this.shouldAcknowledge = shouldAcknowledge
  }

  async start(
    deviceName: string,
    transferPort: number,
    discoveryPort: number,
    localIp: string,
    networkName: string,
    systemVersion: string,
    screenCastPort: number,
    callbacks: DiscoveryCallbacks,
    knownTargets: Array<string> = []
  ): Promise<void> {
    if (this.udp) {
      return
    }
    this.discoveryPort = discoveryPort

    this.beaconDeviceName = deviceName
    this.beaconTransferPort = transferPort
    this.beaconScreenCastPort = screenCastPort
    this.beaconLocalIp = localIp
    this.beaconNetworkName = networkName
    this.beaconSystemVersion = systemVersion

    const udp = socket.constructUDPSocketInstance()
    this.udp = udp

    udp.on('message', (info: socket.SocketMessageInfo) => {
      try {
        const device = JSON.parse(arrayBufferToString(info.message)) as DeviceInfo
        if (device.app !== 'HMTrans' || device.deviceId === this.deviceId) {
          return
        }
        this.receivedPackets += 1
        this.lastReceivedAt = Date.now()
        const advertisedAddress = device.ip
        device.ip = this.resolvePeerAddress(advertisedAddress, info.remoteInfo.address)
        callbacks.onDevice(device)
        // 普通广播只负责“发现”；只有双方仍互相信任时才回送带确认 ID 的单播心跳。
        // 这样解除配对通知偶发失败时，对端也会在 TTL 内从“已连接”降为未配对设备。
        if (this.shouldAcknowledge(device)) {
          this.sendDirectedBeaconIfNeeded(udp, deviceName, transferPort, localIp, networkName, systemVersion,
            screenCastPort, device.deviceId, device.ip)
        }
      } catch (_) {
      }
    })

    udp.on('error', (err) => {
      if (err && err.code === 0) {
        return
      }
      callbacks.onStatus(`发现服务错误：${errorText(err)}`)
    })

    try {
      await udp.bind({
        address: '0.0.0.0',
        port: this.discoveryPort,
      })
    } catch (err) {
      this.udp = undefined
      await udp.close().catch(() => {
      })
      callbacks.onStatus(`发现服务启动失败：${errorText(err)}`)
      throw new Error(errorText(err))
    }

    // 使用局域网受限广播和已配对设备的单播地址，不持续扫描猜测出的私有网段。
    const broadcastAddresses: Array<string> = ['255.255.255.255']
    const beaconTargets = this.uniqueTargets(broadcastAddresses.concat(knownTargets))

    const sendBeacon = async () => {
      const info = createDeviceInfo(
        deviceName, transferPort, this.deviceId, localIp, networkName, systemVersion, this.identityFingerprint,
        undefined, screenCastPort, '0.3.0', ['send-h264']
      )
      for (let index = 0; index < beaconTargets.length; index++) {
        try {
          await udp.send({
            data: JSON.stringify(info),
            address: {
              address: beaconTargets[index],
              port: this.discoveryPort,
            },
          })
          this.sentBeacons += 1
          this.lastSentAt = Date.now()
        } catch (err) {
          // 广播失败过去被静默吞掉，导致「发不出去」和「对方没发」在界面上无法区分。
          this.failedBeacons += 1
          this.lastErrorText = errorText(err as Error)
        }
      }
    }

    await sendBeacon()
    // 两端均在 12 秒后判定设备离线；5 秒心跳允许偶发丢包而不产生单边在线状态。
    this.timer = setInterval(sendBeacon, 5000)
  }

  async stop(): Promise<void> {
    if (this.timer !== undefined) {
      clearInterval(this.timer)
      this.timer = undefined
    }

    const udp = this.udp
    this.udp = undefined
    if (udp) {
      await udp.close().catch(() => {
      })
    }
  }

  /**
   * 向一个已知地址发一次定向发现报文。
   * 设备换了 Wi-Fi 后地址会变，靠它主动把已配对设备找回来，
   * 而不必等下一个广播周期自然撞上。它不改动任何配对状态。
   */
  probe(address: string): void {
    const udp = this.udp
    if (!udp || !this.isUsableAddress(address)) {
      return
    }
    const info = createDeviceInfo(
      this.beaconDeviceName, this.beaconTransferPort, this.deviceId, this.beaconLocalIp,
      this.beaconNetworkName, this.beaconSystemVersion, this.identityFingerprint,
      undefined, this.beaconScreenCastPort, '0.3.0', ['send-h264']
    )
    udp.send({
      data: JSON.stringify(info),
      address: { address: address, port: this.discoveryPort },
    }).catch((err: Error) => {
      console.error(`[HMTrans.Discovery] probe failed address=${address}: ${errorText(err)}`)
    })
  }

  /** 供本地体检读取的收发计数；不参与任何身份判断或配对决策。 */
  stats(): DiscoveryStats {
    return {
      sentBeacons: this.sentBeacons,
      failedBeacons: this.failedBeacons,
      receivedPackets: this.receivedPackets,
      lastSentAt: this.lastSentAt,
      lastReceivedAt: this.lastReceivedAt,
      lastError: this.lastErrorText,
    }
  }

  private uniqueTargets(targets: Array<string>): Array<string> {
    const result: Array<string> = []
    targets.forEach((target: string) => {
      if (target.length > 0 && result.indexOf(target) < 0) {
        result.push(target)
      }
    })
    return result
  }

  private resolvePeerAddress(advertised: string, remote: string): string {
    // 当前 HarmonyOS UDPSocket 某些版本会把 remoteInfo.address 报告为平板本机网卡地址，
    // 而不是数据报发送方地址。优先使用对端广播的局域网地址，仅将 remoteInfo 作为回退。
    return this.isUsableAddress(advertised) ? advertised : remote
  }

  private isUsableAddress(value: string): boolean {
    if (!value || value.length === 0 || value === '0.0.0.0' || value === '127.0.0.1' || value === '::1') {
      return false
    }
    if (/^\d{1,3}(\.\d{1,3}){3}$/.test(value)) {
      return true
    }
    return value.indexOf(':') >= 0 && value.indexOf('::') !== 0
  }

  private sendDirectedBeaconIfNeeded(udp: socket.UDPSocket, deviceName: string, transferPort: number,
    localIp: string, networkName: string, systemVersion: string, screenCastPort: number,
    deviceId: string, address: string): void {
    const now = Date.now()
    if (now - (this.directedReplyAt.get(deviceId) ?? 0) < 2000) return
    this.directedReplyAt.set(deviceId, now)
    const info = createDeviceInfo(
      deviceName, transferPort, this.deviceId, localIp, networkName, systemVersion, this.identityFingerprint, deviceId,
      screenCastPort, '0.3.0', ['send-h264']
    )
    udp.send({
      data: JSON.stringify(info),
      address: {
        address,
        port: this.discoveryPort,
      },
    }).catch((err: Error) => {
      console.error(`[HMTrans.Discovery] acknowledgement failed peer=${deviceId}: ${errorText(err)}`)
    })
  }
}
