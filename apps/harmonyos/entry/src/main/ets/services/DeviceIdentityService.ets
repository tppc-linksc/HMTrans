import { deviceInfo } from '@kit.BasicServicesKit'

/** 统一生成广播和界面使用的本机名称与 HarmonyOS 版本。 */
export class DeviceIdentityService {
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
