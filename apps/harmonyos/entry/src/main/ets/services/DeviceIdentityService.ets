import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit'
import { deviceInfo } from '@kit.BasicServicesKit'
import { distributedDeviceManager } from '@kit.DistributedServiceKit'

const DEVICE_NAME_PERMISSION: Permissions = 'ohos.permission.DISTRIBUTED_DATASYNC'

/** 统一生成广播和界面使用的本机名称与 HarmonyOS 版本。 */
export class DeviceIdentityService {
  async loadUserVisibleDeviceName(context: common.UIAbilityContext): Promise<string> {
    try {
      const accessManager = abilityAccessCtrl.createAtManager()
      const result = await accessManager.requestPermissionsFromUser(context, [DEVICE_NAME_PERMISSION])
      if (result.authResults.length === 0 || result.authResults[0] !== 0) return ''

      const manager = distributedDeviceManager.createDeviceManager(context.abilityInfo.bundleName)
      try {
        return manager.getLocalDeviceName().trim()
      } finally {
        distributedDeviceManager.releaseDeviceManager(manager)
      }
    } catch (_) {
      return ''
    }
  }

  deviceName(savedName: string): string {
    if (savedName.length > 0) return savedName
    if (deviceInfo.marketName && deviceInfo.marketName.length > 0) return deviceInfo.marketName
    if (deviceInfo.productModel && deviceInfo.productModel.length > 0) return deviceInfo.productModel
    return 'HarmonyOS-Device'
  }

  systemVersion(): string {
    const value = deviceInfo.displayVersion.trim()
    const version = value.match(/\d+(?:\.\d+){2,3}/)?.[0] ?? value
    const servicePack = value.match(/SP\d+/i)?.[0]?.toUpperCase() ?? ''
    return `HarmonyOS${version}${servicePack.length > 0 ? ` ${servicePack}` : ''}`
  }
}
