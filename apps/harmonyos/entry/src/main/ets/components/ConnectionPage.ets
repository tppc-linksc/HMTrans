import { uniformTypeDescriptor } from '@kit.ArkData'
import { DeviceInfo } from '../common/Protocol'

// 超过这个数量就不再逐台画满宽卡片：十几台设备排下去会把附近设备区撑得很长，
// 把下方发送区挤出屏幕。改为图标网格后单台设备只占约 66vp，一屏能放两三倍数量。
const DEVICE_ICON_GRID_THRESHOLD: number = 2

/** 连接页面只负责展示，发现与配对仍由控制器管理。 */
@ComponentV2
export struct PadConnectionPage {
  @Param compactLayout: boolean = false
  @Param networkName: string = ''
  @Param localIp: string = ''
  @Param udpPort: number = 0
  @Param tcpPort: number = 0
  @Param pairingCode: string = ''
  @Param pairingSeconds: number = 180
  @Param connectedDevices: Array<DeviceInfo> = []
  @Param offlineDevices: Array<DeviceInfo> = []
  @Param unpairedDevices: Array<DeviceInfo> = []
  @Param reconnectingDeviceIds: Array<string> = []
  @Param selectedDeviceIds: Array<string> = []
  @Param onRegenerateCode: () => void = () => {}
  @Param onPairDevice: (device: DeviceInfo) => void = (_device: DeviceInfo) => {}
  @Param onReconnectDevice: (device: DeviceInfo) => void = (_device: DeviceInfo) => {}
  @Param onToggleTarget: (device: DeviceInfo) => void = (_device: DeviceInfo) => {}
  @Param onForgetDevice: (device: DeviceInfo) => void = (_device: DeviceInfo) => {}
  @Param castState: string = 'idle'
  @Param castDeviceId: string = ''
  @Param castDetail: string = ''
  @Param castStatistics: string = ''
  @Param onStartCast: (device: DeviceInfo) => void = (_device: DeviceInfo) => {}
  @Param onStopCast: () => void = () => {}
  @Param selectedDeviceName: string = ''
  @Param onSelectFile: () => void = () => {}
  @Param onFilesDropped: (event: DragEvent) => void = (_event: DragEvent) => {}

  // 设备数量超过阈值时改用图标网格，点击图标才展开的详情弹层状态，纯本地 UI 状态，
  // 不需要上溯给 Index 页面管理。
  @Local showDeviceDetail: boolean = false
  @Local detailDevice: DeviceInfo | undefined = undefined
  @Local detailDeviceState: string = 'alive'

  build() {
    Column({ space: this.compactLayout ? 14 : 18 }) {
      if (this.compactLayout) {
        // 手机宽度下网络名和配对码各占一整行会把附近设备、发送区挤到屏幕以外；
        // 合并为一张卡片保持视觉重心居中，同时把总高度降到接近桌面双卡片的一半。
        this.CompactStatusCard()
      } else {
        Flex({ direction: FlexDirection.Row, justifyContent: FlexAlign.SpaceBetween }) {
          this.NetworkCard()
          this.PairingCard()
        }
        .width('100%')
      }
      this.NearbyDevicesCard()
      if (this.castState !== 'idle') {
        this.CastStatusCard()
      }
      this.FileSendSection()
    }
    .width('100%')
    .bindContentCover(this.showDeviceDetail, this.DeviceDetailContent(), {
      modalTransition: ModalTransition.DEFAULT,
      onDisappear: () => { this.showDeviceDetail = false },
    })
  }

  @Builder
  private CompactStatusCard() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Image($r('app.media.icon_wifi_discovery')).width(18).height(18)
          .accessibilityText('Wi-Fi')
        Text(this.networkName).fontSize(15).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
          .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.localIp.length > 0 ? this.localIp : '获取地址中')
          .fontSize(11).fontColor($r('app.color.text_secondary')).maxLines(1)
      }.width('100%')
      Divider().strokeWidth(1).color($r('app.color.border_subtle'))
      Row({ space: 14 }) {
        Column({ space: 4 }) {
          Text('本机配对码').fontSize(11).fontColor($r('app.color.text_secondary'))
          Text(this.pairingCode).fontSize(22).fontWeight(FontWeight.Bold).fontColor($r('app.color.accent'))
            .letterSpacing(2)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Stack() {
          Progress({ value: this.pairingSeconds, total: 180, type: ProgressType.Ring })
            .width(46).height(46).color($r('app.color.accent'))
          Text(`${this.pairingSeconds}`).fontSize(12).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
        }.width(46).height(46).onClick(this.onRegenerateCode)
          .accessibilityText(`配对码剩余 ${this.pairingSeconds} 秒`)
          .accessibilityDescription('点按立即生成新的六位配对码')
      }.width('100%')
      Text('在对方 Mac 输入六位码完成首次配对').fontSize(10).fontColor($r('app.color.text_secondary')).width('100%')
    }
    .width('100%').padding(16).backgroundColor($r('app.color.surface_translucent'))
    .backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR).borderRadius(20)
    .border({ width: 1, color: $r('app.color.border_subtle') })
  }

  @Builder
  private CastStatusCard() {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text(this.castState === 'casting' ? '正在投屏' : this.castState === 'failed' ? '投屏异常' : '正在建立投屏')
          .fontSize(15).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
        Text(this.castDetail).fontSize(11).fontColor($r('app.color.text_secondary')).maxLines(2)
        if (this.castStatistics.length > 0) {
          Text(this.castStatistics).fontSize(10).fontColor($r('app.color.accent'))
        }
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Button(this.castState === 'failed' ? '关闭' : '停止投屏')
        .fontSize(12).fontColor($r('app.color.danger')).backgroundColor($r('app.color.danger_surface'))
        .borderRadius(14).onClick(this.onStopCast)
    }.width('100%').padding(16).backgroundColor($r('app.color.surface_translucent'))
      .borderRadius(18).border({ width: 1, color: $r('app.color.border_subtle') })
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
      Text(this.localIp.length > 0 ? this.localIp : '正在获取本机地址')
        .fontSize(12).fontColor($r('app.color.text_secondary')).width('100%')
    }
    .width('49%').height(124).padding(18)
    .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.surface_translucent'))
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
    .width('49%').height(124).padding(18)
    .backgroundColor($r('app.color.surface_translucent')).backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR)
    .borderRadius(20).border({ width: 1, color: $r('app.color.border_subtle') })
  }

  @Builder
  private NearbyDevicesCard() {
    Column({ space: 10 }) {
      Row() {
        Text('附近设备').fontSize(17).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
        Blank()
        Text(`${this.totalDeviceCount()} 台`)
          .fontSize(12).fontColor($r('app.color.text_secondary'))
      }.width('100%')
      if (this.totalDeviceCount() === 0) {
        Text('暂无设备，正在通过局域网自动发现')
          .fontSize(12).fontColor($r('app.color.text_secondary')).width('100%').height(54).textAlign(TextAlign.Center)
      } else if (this.totalDeviceCount() > DEVICE_ICON_GRID_THRESHOLD) {
        this.DeviceIconGrid()
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

  /**
   * 设备很多时改成图标网格：单台设备只占约 66vp（52 图标 + 间距），比满宽卡片省
   * 下大半空间；状态用外框颜色区分，点击图标才展开详情，而不是把每台设备的名称、
   * 系统版本、连接状态都摊在首页上。
   */
  @Builder
  private DeviceIconGrid() {
    Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
      Repeat<DeviceInfo>(this.connectedDevices)
        .each((item) => { this.DeviceIcon(item.item, 'alive') })
        .key((device: DeviceInfo) => `alive-${device.deviceId}`)
      Repeat<DeviceInfo>(this.offlineDevices)
        .each((item) => { this.DeviceIcon(item.item, 'paired') })
        .key((device: DeviceInfo) => `paired-${device.deviceId}`)
      Repeat<DeviceInfo>(this.unpairedDevices)
        .each((item) => { this.DeviceIcon(item.item, 'new') })
        .key((device: DeviceInfo) => `new-${device.deviceId}`)
    }
    .width('100%')
  }

  @Builder
  private DeviceIcon(device: DeviceInfo, state: string) {
    Stack({ alignContent: Alignment.TopEnd }) {
      Stack() {
        Image(device.platform === 'macOS' ? $r('app.media.device_macbook') : $r('app.media.device_matepad'))
          .width(28).height(28)
      }
      .width(52).height(52).borderRadius(26)
      .backgroundColor(state === 'alive' ? $r('app.color.state_connected_surface') :
        state === 'paired' ? $r('app.color.surface_primary') : $r('app.color.accent_surface'))
      .border({ width: 2.5, color: this.statusColor(state) })
      if (state === 'alive' && this.selectedDeviceIds.indexOf(device.deviceId) >= 0) {
        Stack() {
          Text('✓').fontSize(9).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
        }
        .width(16).height(16).borderRadius(8).backgroundColor($r('app.color.accent_strong'))
        .border({ width: 1.5, color: $r('app.color.surface_primary') })
      }
    }
    .margin({ right: 14, bottom: 6 })
    .onClick(() => {
      this.detailDevice = device
      this.detailDeviceState = state
      this.showDeviceDetail = true
    })
    .accessibilityText(`${device.deviceName}，${state === 'alive' ? '已连接' : state === 'paired' ? '已配对未连接' : '未配对'}`)
    .accessibilityDescription('点按查看设备详情')
  }

  private isReconnecting(device: DeviceInfo): boolean {
    return this.reconnectingDeviceIds.indexOf(device.deviceId) >= 0
  }

  private pairedStatusText(device: DeviceInfo): string {
    return this.isReconnecting(device) ? '正在重新连接…' : '已配对 · 点击重新连接'
  }

  /** 蓝色＝识别到但未连接，绿色＝已连接，灰色＝配对过但当前未检测到。 */
  private statusColor(state: string): ResourceColor {
    if (state === 'alive') return $r('app.color.success')
    if (state === 'paired') return $r('app.color.text_secondary')
    return $r('app.color.accent')
  }

  @Builder
  private DeviceDetailContent() {
    Column() {
      if (this.detailDevice) {
        this.DeviceDetailCard(this.detailDevice, this.detailDeviceState)
      }
    }
    .width('100%').height('100%').justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.scrim'))
    .onClick(() => { this.showDeviceDetail = false })
  }

  @Builder
  private DeviceDetailCard(device: DeviceInfo, state: string) {
    Column({ space: 16 }) {
      Stack() {
        Image(device.platform === 'macOS' ? $r('app.media.device_macbook') : $r('app.media.device_matepad'))
          .width(38).height(38)
      }
      .width(72).height(72).borderRadius(36)
      .backgroundColor(state === 'alive' ? $r('app.color.state_connected_surface') :
        state === 'paired' ? $r('app.color.surface_primary') : $r('app.color.accent_surface'))
      .border({ width: 3, color: this.statusColor(state) })
      Column({ space: 4 }) {
        Text(device.deviceName).fontSize(19).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary')).textAlign(TextAlign.Center).maxLines(2)
        Text(this.systemVersionLabel(device)).fontSize(12).fontColor($r('app.color.text_secondary'))
          .textAlign(TextAlign.Center)
        Text(state === 'alive' ? `已连接 · ${device.ip}` :
          state === 'paired' ? this.pairedStatusText(device) : '新设备 · 尚未配对')
          .fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.statusColor(state)).textAlign(TextAlign.Center)
      }.width('100%')
      Column({ space: 10 }) {
        if (state === 'new') {
          this.DetailActionButton('输入配对码', true, false,
            () => { this.onPairDevice(device); this.showDeviceDetail = false })
        }
        if (state === 'paired') {
          this.DetailActionButton(this.isReconnecting(device) ? '正在重新连接…' : '重新连接', true, false,
            () => { this.onReconnectDevice(device); this.showDeviceDetail = false })
          this.DetailActionButton('忘记设备', false, true,
            () => { this.onForgetDevice(device); this.showDeviceDetail = false })
        }
        if (state === 'alive') {
          this.DetailActionButton(
            this.selectedDeviceIds.indexOf(device.deviceId) >= 0 ? '取消选为发送目标' : '选为发送目标',
            true, false, () => { this.onToggleTarget(device); this.showDeviceDetail = false })
          if (this.canStartScreenCast(device)) {
            this.DetailActionButton(this.isCasting(device) ? '停止投屏' : '开始投屏', false, this.isCasting(device),
              () => {
                if (this.isCasting(device)) this.onStopCast(); else this.onStartCast(device)
                this.showDeviceDetail = false
              })
          }
          this.DetailActionButton('忘记设备', false, true,
            () => { this.onForgetDevice(device); this.showDeviceDetail = false })
        }
      }.width('100%')
      Text('关闭').fontSize(14).fontColor($r('app.color.text_secondary'))
        .onClick(() => { this.showDeviceDetail = false })
    }
    .width('86%').constraintSize({ maxWidth: 380 }).padding(24)
    .backgroundColor($r('app.color.surface_primary')).borderRadius(22)
    .shadow({ radius: 20, color: '#0000001A', offsetY: 8 })
    .onClick(() => {})
  }

  @Builder
  private DetailActionButton(title: string, primary: boolean, danger: boolean, action: () => void) {
    Button(title).width('100%').height(44).fontSize(15).fontWeight(FontWeight.Medium)
      .fontColor(primary ? '#FFFFFF' : danger ? $r('app.color.danger') : $r('app.color.text_primary'))
      .backgroundColor(primary ? $r('app.color.accent_strong') :
        danger ? $r('app.color.danger_surface') : $r('app.color.control_track'))
      .borderRadius(12).onClick(action)
  }

  private totalDeviceCount(): number {
    return this.connectedDevices.length + this.offlineDevices.length + this.unpairedDevices.length
  }

  private isCasting(device: DeviceInfo): boolean {
    return this.castDeviceId === device.deviceId && this.castState !== 'idle'
  }

  @Builder
  private DeviceCard(device: DeviceInfo, state: string) {
    Row({ space: 9 }) {
      Image(device.platform === 'macOS' ? $r('app.media.device_macbook') : $r('app.media.device_matepad'))
        .width(34).height(34).borderRadius(10)
      Column({ space: 3 }) {
        Text(device.deviceName).fontSize(13).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).maxLines(1)
        Text(this.systemVersionLabel(device)).fontSize(9).fontColor($r('app.color.text_secondary')).maxLines(1)
        Text(state === 'alive' ? `已连接 · ${device.ip}` :
          state === 'paired' ? this.pairedStatusText(device) : '新设备 · 点击输入配对码')
          .fontSize(10).fontColor(state === 'alive' ? $r('app.color.success') :
            state === 'paired' ? $r('app.color.accent') : $r('app.color.text_secondary')).maxLines(1)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      if (state === 'alive' && this.canStartScreenCast(device)) {
        Button(this.castDeviceId === device.deviceId && this.castState !== 'idle' ? '停止' : '投屏')
          .fontSize(10).height(28).padding({ left: 9, right: 9 })
          .fontColor(this.castDeviceId === device.deviceId && this.castState !== 'idle' ?
            $r('app.color.danger') : $r('app.color.accent'))
          .backgroundColor(this.castDeviceId === device.deviceId && this.castState !== 'idle' ?
            $r('app.color.danger_surface') : $r('app.color.accent_surface'))
          .borderRadius(12).onClick(() => {
            if (this.castDeviceId === device.deviceId && this.castState !== 'idle') this.onStopCast()
            else this.onStartCast(device)
          })
      } else {
        Text(state === 'alive' && this.selectedDeviceIds.indexOf(device.deviceId) >= 0 ? '✓' : state === 'alive' ? '●' : '›')
          .fontSize(state === 'alive' ? 16 : 22)
          .fontColor(state === 'alive' ? $r('app.color.success') :
            state === 'paired' ? $r('app.color.accent') : $r('app.color.text_secondary'))
      }
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

  /** 只有明确广播 v0.3 H.264 接收能力的 Mac 才显示投屏入口。 */
  private canStartScreenCast(device: DeviceInfo): boolean {
    const capabilities = device.screenCastCapabilities ?? []
    return device.platform === 'macOS' && device.screenCastProtocolVersion === '0.3.0' &&
      capabilities.indexOf('receive-h264') >= 0 && (device.screenCastPort ?? 0) > 0
  }
}
