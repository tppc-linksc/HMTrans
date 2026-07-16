import { common } from '@kit.AbilityKit'
import { preferences } from '@kit.ArkData'
import { util } from '@kit.ArkTS'
import { DEFAULT_PORT, DISCOVERY_PORT } from '../common/Protocol'
import { errorText } from '../common/ErrorText'

const NAME: string = 'HMTrans'
const TRUST_KEY: string = 'trustedDeviceIdsV3DeviceSnapshot'

export interface PadPreferencesSnapshot {
  host: string
  remotePort: string
  localTcpPort: string
  discoveryPort: string
  deviceId: string
  identityFingerprint: string
  trustedDeviceIds: Array<string>
  trustedFingerprints: Map<string, string>
  backgroundProtectionEnabled: boolean
  autoReceiveTrustedEnabled: boolean
  receiverEnabled: boolean
  discoveryEnabled: boolean
}

/** 用户设置与安装身份的强类型持久化边界。 */
export class PadPreferencesService {
  async load(context: common.UIAbilityContext): Promise<PadPreferencesSnapshot> {
    try {
      const store = await preferences.getPreferences(context, NAME)
      let deviceId = await store.get('deviceId', '') as string
      let fingerprint = await store.get('identityFingerprint', '') as string
      if (deviceId.length === 0) deviceId = `pad-${Date.now()}-${Math.floor(Math.random() * 100000)}`
      if (fingerprint.length === 0) fingerprint = util.generateRandomUUID(false).replace(/-/g, '').toLowerCase()
      await store.put('deviceId', deviceId)
      await store.put('identityFingerprint', fingerprint)
      await store.flush()

      const trustedText = await store.get(TRUST_KEY, '') as string
      const trustedFingerprints: Map<string, string> = new Map()
      try {
        const values = JSON.parse(await store.get('trustedDeviceFingerprintsV1', '{}') as string) as Record<string, string>
        Object.keys(values).forEach((key: string) => trustedFingerprints.set(key, values[key]))
      } catch (_) {}

      return {
        host: await store.get('lastHost', '') as string,
        remotePort: await store.get('lastPort', `${DEFAULT_PORT}`) as string,
        localTcpPort: await store.get('localTcpPort', `${DEFAULT_PORT}`) as string,
        discoveryPort: await store.get('discoveryPort', `${DISCOVERY_PORT}`) as string,
        deviceId,
        identityFingerprint: fingerprint,
        trustedDeviceIds: trustedText.length > 0 ? trustedText.split(',') : [],
        trustedFingerprints,
        backgroundProtectionEnabled: await store.get('backgroundProtectionEnabled', true) as boolean,
        autoReceiveTrustedEnabled: await store.get('autoReceiveTrustedEnabled', true) as boolean,
        receiverEnabled: await store.get('receiverEnabled', true) as boolean,
        discoveryEnabled: await store.get('discoveryEnabled', true) as boolean,
      }
    } catch (err) {
      throw new Error(`偏好读取失败：${errorText(err)}`)
    }
  }

  async saveTarget(context: common.UIAbilityContext, host: string, port: string): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, NAME)
      await store.put('lastHost', host); await store.put('lastPort', port); await store.flush()
    } catch (err) {
      throw new Error(`目标地址保存失败：${errorText(err)}`)
    }
  }

  async savePorts(context: common.UIAbilityContext, tcp: string, udp: string): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, NAME)
      await store.put('localTcpPort', tcp); await store.put('discoveryPort', udp); await store.flush()
    } catch (err) {
      throw new Error(`端口设置保存失败：${errorText(err)}`)
    }
  }

  async saveTrust(context: common.UIAbilityContext, ids: Array<string>, fingerprints: Map<string, string>): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, NAME)
      const values: Record<string, string> = {}
      fingerprints.forEach((value: string, key: string) => { values[key] = value })
      await store.put(TRUST_KEY, ids.join(','))
      await store.put('trustedDeviceFingerprintsV1', JSON.stringify(values))
      await store.flush()
    } catch (err) {
      throw new Error(`配对信任保存失败：${errorText(err)}`)
    }
  }

  async saveBoolean(context: common.UIAbilityContext, key: string, value: boolean): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, NAME)
      await store.put(key, value)
      await store.flush()
    } catch (err) {
      throw new Error(`设置保存失败：${errorText(err)}`)
    }
  }

}
