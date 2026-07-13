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

  constructor(deviceId: string, identityFingerprint: string) {
    this.deviceId = deviceId
    this.identityFingerprint = identityFingerprint
  }

  async start(
    deviceName: string,
    transferPort: number,
    discoveryPort: number,
    networkName: string,
    systemVersion: string,
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
        this.sendDirectedBeaconIfNeeded(udp, deviceName, transferPort, networkName, systemVersion,
          device.deviceId, device.ip)
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

    // Use the LAN limited broadcast and paired-device unicast targets instead
    // of continuously sweeping guessed private subnets.
    const broadcastAddresses: Array<string> = ['255.255.255.255']
    const beaconTargets = this.uniqueTargets(broadcastAddresses.concat(knownTargets))

    const sendBeacon = async () => {
      const info = createDeviceInfo(
        deviceName, transferPort, this.deviceId, networkName, systemVersion, this.identityFingerprint
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
    // Both clients expire a device after 12 seconds. A five-second heartbeat
    // leaves room for one dropped packet without showing asymmetric state.
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
    // On current HarmonyOS UDPSocket builds, remoteInfo.address can report the
    // tablet's local interface address instead of the datagram sender. Prefer
    // the peer's advertised LAN address and retain remoteInfo only as fallback.
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
    networkName: string, systemVersion: string, deviceId: string, address: string): void {
    const now = Date.now()
    if (now - (this.directedReplyAt.get(deviceId) ?? 0) < 2000) return
    this.directedReplyAt.set(deviceId, now)
    const info = createDeviceInfo(
      deviceName, transferPort, this.deviceId, networkName, systemVersion, this.identityFingerprint, deviceId
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
