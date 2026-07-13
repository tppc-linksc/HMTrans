import { uniformTypeDescriptor } from '@kit.ArkData'
import { DeviceInfo } from '../common/Protocol'

/** 连接页面只负责展示，发现与配对仍由控制器管理。 */
@ComponentV2
export struct PadConnectionPage {
  @Param compactLayout: boolean = false
  @Param networkName: string = ''
  @Param targetIp: string = ''
  @Param udpPort: number = 0
  @Param tcpPort: number = 0
  @Param pairingCode: string = ''
  @Param pairingSeconds: number = 180
  @Param connectedDevices: Array<DeviceInfo> = []
  @Param offlineDevices: Array<DeviceInfo> = []
  @Param unpairedDevices: Array<DeviceInfo> = []
  @Param selectedDeviceIds: Array<string> = []
  @Param onRegenerateCode: () => void = () => {}
  @Param onPairDevice: (device: DeviceInfo) => void = (_device: DeviceInfo) => {}
  @Param onReconnectDevice: (device: DeviceInfo) => void = (_device: DeviceInfo) => {}
  @Param onToggleTarget: (device: DeviceInfo) => void = (_device: DeviceInfo) => {}
  @Param onForgetDevice: (device: DeviceInfo) => void = (_device: DeviceInfo) => {}
  @Param selectedDeviceName: string = ''
  @Param onSelectFile: () => void = () => {}
  @Param onFilesDropped: (event: DragEvent) => void = (_event: DragEvent) => {}

  build() {
    Column({ space: 18 }) {
      Flex({ direction: this.compactLayout ? FlexDirection.Column : FlexDirection.Row,
        justifyContent: FlexAlign.SpaceBetween }) {
        this.NetworkCard()
        this.PairingCard()
      }
      .width('100%')
      this.NearbyDevicesCard()
      this.FileSendSection()
    }
    .width('100%')
  }

  @Builder
  private NetworkCard() {
    Column({ space: 7 }) {
      Text('当前网络').fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
      Row({ space: 8 }) {
        Image($r('app.media.icon_wifi_discovery')).width(22).height(22)
          .accessibilityText('Wi-Fi')
        Text(this.networkName).fontSize(19).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
      }.width('100%')
      Text(this.targetIp.length > 0 ? this.targetIp : '自动获取地址')
        .fontSize(12).fontColor($r('app.color.text_secondary')).width('100%')
    }
    .width(this.compactLayout ? '100%' : '49%').height(124).padding(18)
    .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Start)
    .margin({ bottom: this.compactLayout ? 12 : 0 }).backgroundColor($r('app.color.surface_translucent'))
    .backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR).borderRadius(20)
    .border({ width: 1, color: $r('app.color.border_subtle') })
  }

  /** 发送目标由已选中的连接设备决定，与 Mac 连接页逻辑一致。 */
  @Builder
  private FileSendSection() {
    Column({ space: 9 }) {
      Text('+').fontSize(38).fontColor($r('app.color.accent_strong')).textAlign(TextAlign.Center)
        .width(56).height(56).backgroundColor($r('app.color.accent_soft_surface')).borderRadius(28)
      Text(this.selectedDeviceName.length > 0 ? '点击选择文件或文件夹并发送' : '暂无已连接设备')
        .fontSize(17).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).textAlign(TextAlign.Center)
      Text(this.selectedDeviceName.length > 0 ? `发送给 ${this.selectedDeviceName}` : '请先在上方完成发现、配对并选择设备')
        .fontSize(12).fontColor($r('app.color.text_secondary')).textAlign(TextAlign.Center).maxLines(2)
    }
    .width('100%').height(230).justifyContent(FlexAlign.Center).backgroundColor($r('app.color.surface_primary'))
    .borderRadius(24).border({ width: 2, color: $r('app.color.accent'), style: BorderStyle.Dashed })
    .enabled(this.selectedDeviceName.length > 0).onClick(this.onSelectFile)
    .accessibilityText(this.selectedDeviceName.length > 0 ? '选择文件或文件夹并发送' : '暂无已连接设备')
    .accessibilityDescription(this.selectedDeviceName.length > 0 ? `发送给 ${this.selectedDeviceName}` : '请先连接设备')
    .allowDrop([
      uniformTypeDescriptor.UniformDataType.FILE,
      uniformTypeDescriptor.UniformDataType.FOLDER,
      uniformTypeDescriptor.UniformDataType.FILE_URI,
    ])
    .onDrop(this.onFilesDropped)
  }

  @Builder
  private PairingCard() {
    Row({ space: 18 }) {
      Column({ space: 7 }) {
        Text('本机配对码').fontSize(13).fontColor($r('app.color.text_secondary'))
        Text(this.pairingCode).fontSize(26).fontWeight(FontWeight.Bold).fontColor($r('app.color.accent')).letterSpacing(3)
        Text('在对方 Mac 输入六位码完成首次配对').fontSize(11).fontColor($r('app.color.text_secondary'))
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Stack() {
        Progress({ value: this.pairingSeconds, total: 180, type: ProgressType.Ring })
          .width(58).height(58).color($r('app.color.accent'))
        Column({ space: 0 }) {
          Text(`${this.pairingSeconds}`).fontSize(13).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
          Text('秒').fontSize(9).fontColor($r('app.color.text_secondary'))
        }
      }.width(58).height(58).onClick(this.onRegenerateCode)
        .accessibilityText(`配对码剩余 ${this.pairingSeconds} 秒`)
        .accessibilityDescription('点按立即生成新的六位配对码')
    }
    .width(this.compactLayout ? '100%' : '49%').height(124).padding(18)
    .backgroundColor($r('app.color.surface_translucent')).backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR)
    .borderRadius(20).border({ width: 1, color: $r('app.color.border_subtle') })
  }

  @Builder
  private NearbyDevicesCard() {
    Column({ space: 10 }) {
      Row() {
        Text('附近设备').fontSize(17).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
        Blank()
        Text(`${this.connectedDevices.length + this.offlineDevices.length + this.unpairedDevices.length} 台`)
          .fontSize(12).fontColor($r('app.color.text_secondary'))
      }.width('100%')
      if (this.connectedDevices.length + this.offlineDevices.length + this.unpairedDevices.length === 0) {
        Text('暂无设备，正在通过局域网自动发现')
          .fontSize(12).fontColor($r('app.color.text_secondary')).width('100%').height(54).textAlign(TextAlign.Center)
      } else {
        Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
          Repeat<DeviceInfo>(this.connectedDevices)
            .each((item) => { this.DeviceCard(item.item, 'alive') })
            .key((device: DeviceInfo) => `alive-${device.deviceId}`)
          Repeat<DeviceInfo>(this.offlineDevices)
            .each((item) => { this.DeviceCard(item.item, 'paired') })
            .key((device: DeviceInfo) => `paired-${device.deviceId}`)
          Repeat<DeviceInfo>(this.unpairedDevices)
            .each((item) => { this.DeviceCard(item.item, 'new') })
            .key((device: DeviceInfo) => `new-${device.deviceId}`)
        }
        .width('100%')
      }
    }
    .width('100%').padding(14).backgroundColor($r('app.color.surface_translucent')).borderRadius(20)
    .border({ width: 1, color: $r('app.color.border_subtle') })
  }

  @Builder
  private DeviceCard(device: DeviceInfo, state: string) {
    Row({ space: 9 }) {
      Image(device.platform === 'macOS' ? $r('app.media.device_macbook') : $r('app.media.device_matepad'))
        .width(34).height(34).borderRadius(10)
      Column({ space: 3 }) {
        Text(device.deviceName).fontSize(13).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).maxLines(1)
        Text(this.systemVersionLabel(device)).fontSize(9).fontColor($r('app.color.text_secondary')).maxLines(1)
        Text(state === 'alive' ? `已连接 · ${device.ip}` : state === 'paired' ? '已配对 · 点击重新连接' : '新设备 · 点击输入配对码')
          .fontSize(10).fontColor(state === 'alive' ? $r('app.color.success') :
            state === 'paired' ? $r('app.color.accent') : $r('app.color.text_secondary')).maxLines(1)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text(state === 'alive' && this.selectedDeviceIds.indexOf(device.deviceId) >= 0 ? '✓' : state === 'alive' ? '●' : '›')
        .fontSize(state === 'alive' ? 16 : 22)
        .fontColor(state === 'alive' ? $r('app.color.success') :
          state === 'paired' ? $r('app.color.accent') : $r('app.color.text_secondary'))
    }
    .width(this.compactLayout ? '100%' : 250).height(66).padding({ left: 11, right: 11 })
    .margin({ right: 10, bottom: 10 })
    .backgroundColor(state === 'alive' ? $r('app.color.state_connected_surface') :
      state === 'paired' ? $r('app.color.state_paired_surface') : $r('app.color.surface_primary'))
    .borderRadius(17)
    .border({ width: this.selectedDeviceIds.indexOf(device.deviceId) >= 0 ? 2 : 1,
      color: this.selectedDeviceIds.indexOf(device.deviceId) >= 0 ? $r('app.color.accent') :
        state === 'alive' ? $r('app.color.state_connected_border') :
          state === 'paired' ? $r('app.color.state_paired_border') : $r('app.color.divider') })
    .onClick(() => {
      if (state === 'new') this.onPairDevice(device)
      else if (state === 'paired') this.onReconnectDevice(device)
      else this.onToggleTarget(device)
    })
    .accessibilityText(`${device.deviceName}，${state === 'alive' ? '已连接' : state === 'paired' ? '已配对未连接' : '未配对'}`)
    .accessibilityDescription(state === 'alive' ? '点按选择或取消发送目标，长按可忘记设备' :
      state === 'paired' ? '点按重新连接，长按可忘记设备' : '点按输入配对码')
    .gesture(
      LongPressGesture({ repeat: false, duration: 600 })
        .onAction(() => {
          if (state !== 'new') this.onForgetDevice(device)
        })
    )
  }

  /** 将 Apple 广播的版本信息规范为双端一致的简洁产品文案。 */
  private systemVersionLabel(device: DeviceInfo): string {
    const raw = device.systemVersion ?? device.version
    if (device.platform !== 'macOS') return `${device.platform} ${raw}`
    let version = raw
    if (version.startsWith('macOS ')) version = version.substring(6)
    if (version.startsWith('Version ')) version = version.substring(8)
    const buildStart = version.indexOf('(Build ')
    if (buildStart < 0) return `macOS ${version}`
    const release = version.substring(0, buildStart).trim()
    const build = version.substring(buildStart + 7, version.lastIndexOf(')')).trim()
    return `macOS ${release} Beta版（${build}）`
  }
}
