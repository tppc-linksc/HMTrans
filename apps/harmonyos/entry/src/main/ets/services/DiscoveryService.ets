import { socket } from '@kit.NetworkKit'
import { arrayBufferToString } from '../common/Bytes'
import { DISCOVERY_PORT, DeviceInfo, createDeviceInfo } from '../common/Protocol'
import { errorText } from '../common/ErrorText'

export interface DiscoveryCallbacks {
  onDevice: (device: DeviceInfo) => void
  onStatus: (value: string) => void
}

export class DiscoveryService {
  private udp?: socket.UDPSocket
  private timer?: number
  private deviceId: string
  private discoveryPort: number = DISCOVERY_PORT
  private identityFingerprint: string
  private directedReplyAt: Map<string, number> = new Map()
  private shouldAcknowledge: (device: DeviceInfo) => boolean

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

    const udp = socket.constructUDPSocketInstance()
    this.udp = udp

    udp.on('message', (info: socket.SocketMessageInfo) => {
      try {
        const device = JSON.parse(arrayBufferToString(info.message)) as DeviceInfo
        if (device.app !== 'HMTrans' || device.deviceId === this.deviceId) {
          return
        }
        const advertisedAddress = device.ip
        device.ip = this.resolvePeerAddress(advertisedAddress, info.remoteInfo.address)
        callbacks.onDevice(device)
        // 普通广播只负责“发现”；只有双方仍互相信任时才回送带确认 ID 的单播心跳。
        // 这样解除配对通知偶发失败时，对端也会在 TTL 内从“已连接”降为未配对设备。
        if (this.shouldAcknowledge(device)) {
          this.sendDirectedBeaconIfNeeded(udp, deviceName, transferPort, networkName, systemVersion,
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
        deviceName, transferPort, this.deviceId, networkName, systemVersion, this.identityFingerprint,
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
        } catch (_) {
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
    networkName: string, systemVersion: string, screenCastPort: number, deviceId: string, address: string): void {
    const now = Date.now()
    if (now - (this.directedReplyAt.get(deviceId) ?? 0) < 2000) return
    this.directedReplyAt.set(deviceId, now)
    const info = createDeviceInfo(
      deviceName, transferPort, this.deviceId, networkName, systemVersion, this.identityFingerprint, deviceId,
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
