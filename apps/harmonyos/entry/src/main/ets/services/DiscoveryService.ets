import { socket } from '@kit.NetworkKit'
import { arrayBufferToString } from '../common/Bytes'
import { DISCOVERY_PORT, DeviceInfo, createDeviceInfo } from '../common/Protocol'

export interface DiscoveryCallbacks {
  onDevice: (device: DeviceInfo) => void
  onStatus: (value: string) => void
}

export class DiscoveryService {
  private udp?: socket.UDPSocket
  private timer?: number
  private deviceId: string

  constructor(deviceId: string) {
    this.deviceId = deviceId
  }

  async start(
    deviceName: string,
    transferPort: number,
    callbacks: DiscoveryCallbacks,
    knownTargets: Array<string> = []
  ): Promise<void> {
    if (this.udp) {
      return
    }

    const udp = socket.constructUDPSocketInstance()
    this.udp = udp

    udp.on('message', (info: socket.SocketMessageInfo) => {
      try {
        const device = JSON.parse(arrayBufferToString(info.message)) as DeviceInfo
        if (device.app !== 'HMTrans' || device.deviceId === this.deviceId) {
          return
        }
        device.ip = this.resolvePeerAddress(device.ip, info.remoteInfo.address)
        callbacks.onDevice(device)
        this.sendDirectedBeacon(udp, deviceName, transferPort, device.ip)
      } catch (_) {
      }
    })

    udp.on('error', (err) => {
      if (err && err.code === 0) {
        return
      }
      callbacks.onStatus(`发现服务错误：${JSON.stringify(err)}`)
    })

    try {
      await udp.bind({
        address: '0.0.0.0',
        port: DISCOVERY_PORT,
      })
    } catch (err) {
      this.udp = undefined
      await udp.close().catch(() => {
      })
      callbacks.onStatus(`发现服务启动失败：${JSON.stringify(err)}`)
      throw new Error(JSON.stringify(err))
    }

    const broadcastAddresses: Array<string> = [
      '255.255.255.255',
      '192.168.0.255',
      '192.168.1.255',
      '192.168.2.255',
      '192.168.3.255',
      '192.168.31.255',
      '192.168.50.255',
      '10.0.0.255',
      '10.0.1.255',
      '172.16.0.255',
      '172.17.0.255',
      '172.18.0.255',
      '172.19.0.255',
      '172.20.0.255',
      '172.21.0.255',
      '172.22.0.255',
      '172.23.0.255',
      '172.24.0.255',
      '172.25.0.255',
      '172.26.0.255',
      '172.27.0.255',
      '172.28.0.255',
      '172.29.0.255',
      '172.30.0.255',
      '172.31.0.255',
    ]
    const beaconTargets = this.uniqueTargets(broadcastAddresses.concat(knownTargets))

    const sendBeacon = async () => {
      const info = createDeviceInfo(deviceName, transferPort, this.deviceId)
      for (let index = 0; index < beaconTargets.length; index++) {
        try {
          await udp.send({
            data: JSON.stringify(info),
            address: {
              address: beaconTargets[index],
              port: DISCOVERY_PORT,
            },
          })
        } catch (_) {
        }
      }
    }

    await sendBeacon()
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

  private sendDirectedBeacon(udp: socket.UDPSocket, deviceName: string, transferPort: number, address: string): void {
    const info = createDeviceInfo(deviceName, transferPort, this.deviceId)
    udp.send({
      data: JSON.stringify(info),
      address: {
        address,
        port: DISCOVERY_PORT,
      },
    }).catch(() => {
    })
  }
}
