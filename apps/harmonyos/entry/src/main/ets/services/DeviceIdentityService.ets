import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit'
import { deviceInfo } from '@kit.BasicServicesKit'
import { distributedDeviceManager } from '@kit.DistributedServiceKit'
import { errorText } from '../common/ErrorText'

const DEVICE_NAME_PERMISSION: Permissions = 'ohos.permission.DISTRIBUTED_DATASYNC'

/** 统一生成广播和界面使用的本机名称与 HarmonyOS 版本。 */
export class DeviceIdentityService {
  async loadUserVisibleDeviceName(context: common.UIAbilityContext): Promise<string> {
    try {
      const accessManager = abilityAccessCtrl.createAtManager()
      const result = await accessManager.requestPermissionsFromUser(context, [DEVICE_NAME_PERMISSION])
      if (result.authResults.length === 0 || result.authResults[0] !== 0) {
        throw new Error('读取本机设备名称需要允许跨设备协同权限')
      }

      const manager = distributedDeviceManager.createDeviceManager(context.abilityInfo.bundleName)
      try {
        const name = manager.getLocalDeviceName().trim()
        if (name.length === 0) {
          throw new Error('系统未返回本机设备名称，请确认签名 Profile 已包含设备名称 ACL')
        }
        return name
      } finally {
        try {
          distributedDeviceManager.releaseDeviceManager(manager)
        } catch (_) {}
      }
    } catch (err) {
      throw new Error(`本机设备名称读取失败：${errorText(err)}`)
    }
  }

  deviceName(authorizedName: string): string {
    return authorizedName.trim()
  }

  systemVersion(): string {
    const value = deviceInfo.displayVersion.trim()
    const version = value.match(/\d+(?:\.\d+){2,3}/)?.[0] ?? value
    const servicePack = value.match(/SP\d+/i)?.[0]?.toUpperCase() ?? ''
    return `HarmonyOS${version}${servicePack.length > 0 ? ` ${servicePack}` : ''}`
  }
}
