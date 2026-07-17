/** 设置页只负责展示，每个开关和操作都委托给真实服务。 */
@ComponentV2
export struct PadSettingsPage {
  @Param receiverEnabled: boolean = true
  @Param discoveryEnabled: boolean = true
  @Param backgroundProtectionEnabled: boolean = true
  @Param autoReceiveTrustedEnabled: boolean = true
  @Param udpPort: number = 51889
  @Param tcpPort: number = 51888
  @Param networkServiceReady: boolean = false
  @Param castPort: number = 51890
  @Param castResolution: string = '1080p'
  @Param castFrameRate: number = 60
  @Param networkTestState: string = 'idle'
  @Param networkTestDetail: string = '测试 Pad 到 Mac 的实际投屏链路'
  @Param downloadDirectoryReady: boolean = false
  @Param onReceiverChanged: (enabled: boolean) => void = (_enabled: boolean) => {}
  @Param onDiscoveryChanged: (enabled: boolean) => void = (_enabled: boolean) => {}
  @Param onBackgroundChanged: (enabled: boolean) => void = (_enabled: boolean) => {}
  @Param onAutoReceiveChanged: (enabled: boolean) => void = (_enabled: boolean) => {}
  @Param onClearStaging: () => void = () => {}
  @Param onCheckDownload: () => void = () => {}
  @Param onEditPorts: () => void = () => {}
  @Param onEditCast: () => void = () => {}
  @Param onTestCastNetwork: () => void = () => {}
  @Param onOpenPrivacy: () => void = () => {}
  @Param onCopyDiagnostics: () => void = () => {}

  build() {
    Column({ space: 14 }) {
      Column({ space: 0 }) {
        this.ToggleRow('接收服务', '允许已配对设备向本机发送文件', this.receiverEnabled, this.onReceiverChanged)
        Divider().color($r('app.color.divider'))
        this.ToggleRow('自动发现', '前台快速扫描，后台空闲时自动降频', this.discoveryEnabled, this.onDiscoveryChanged)
        Divider().color($r('app.color.divider'))
        this.ToggleRow('已配对设备自动接收', '陌生设备仍需要六位码确认',
          this.autoReceiveTrustedEnabled, this.onAutoReceiveChanged)
        Divider().color($r('app.color.divider'))
        this.ToggleRow('后台传输保护', '仅在活动传输期间启用长时任务',
          this.backgroundProtectionEnabled, this.onBackgroundChanged)
        Divider().color($r('app.color.divider'))
        this.ActionRow('诊断信息', '不包含文件内容、完整路径或局域网地址', '复制', this.onCopyDiagnostics)
        Divider().color($r('app.color.divider'))
        this.ActionRow('下载目录',
          `Download/HMTrans · ${this.downloadDirectoryReady ? '已授权且只显示成功文件' : '需要授权后才能接收文件'}`,
          '检查', this.onCheckDownload)
        Divider().color($r('app.color.divider'))
        this.ActionRow('临时传输空间', '应用私有 · 未完成任务可恢复', '清除', this.onClearStaging)
        Divider().color($r('app.color.divider'))
        this.NavigationRow('网络服务',
          `UDP ${this.udpPort} · TCP ${this.tcpPort} · ${this.networkServiceReady ? '运行正常' : '已关闭'}`,
          this.onEditPorts)
        Divider().color($r('app.color.divider'))
        this.NavigationRow('投屏',
          `${this.resolutionLabel()} · ${this.castFrameRate}P · TCP ${this.castPort} · 仅 MatePad 投屏到 Mac`,
          this.onEditCast)
        Divider().color($r('app.color.divider'))
        this.ActionRow('投屏网络测试', this.networkTestDetail,
          this.networkTestState === 'running' ? '测试中' : '开始', this.onTestCastNetwork)
      }.width('100%').padding({ left: 18, right: 18 }).backgroundColor($r('app.color.surface_translucent'))
        .borderRadius(22).border({ width: 1, color: $r('app.color.border_subtle') })
      Row() {
        Column({ space: 4 }) {
          Text('隐私与本地数据').fontSize(15).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
          Text('无账号 · 无云端 · 配对关系仅保存在本机').fontSize(11).fontColor($r('app.color.text_secondary'))
        }.alignItems(HorizontalAlign.Start)
        Blank()
        Button('查看隐私政策').fontSize(12).onClick(this.onOpenPrivacy)
      }.width('100%').padding(18).backgroundColor($r('app.color.surface_translucent')).borderRadius(22)
        .border({ width: 1, color: $r('app.color.border_subtle') })
    }.width('100%')
  }

  private resolutionLabel(): string {
    if (this.castResolution === '720p') return '720P 级'
    if (this.castResolution === '2k') return '2K 级'
    return '1080P 级'
  }

  @Builder
  private ToggleRow(title: string, subtitle: string, enabled: boolean, onChange: (value: boolean) => void) {
    Row() {
      Column({ space: 4 }) {
        Text(title).fontSize(15).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
        Text(subtitle).fontSize(11).fontColor($r('app.color.text_secondary'))
      }.alignItems(HorizontalAlign.Start)
      Blank()
      Toggle({ type: ToggleType.Switch, isOn: enabled }).width(46).height(24)
        .selectedColor($r('app.color.accent')).onChange(onChange)
        .accessibilityText(title)
        .accessibilityDescription(`${subtitle}，当前${enabled ? '开启' : '关闭'}`)
    }.width('100%').height(72)
  }

  @Builder
  private ActionRow(title: string, subtitle: string, action: string, onClick: () => void) {
    Row() {
      Column({ space: 4 }) {
        Text(title).fontSize(15).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
        Text(subtitle).fontSize(11).fontColor($r('app.color.text_secondary'))
      }.alignItems(HorizontalAlign.Start)
      Blank()
      Button(action).fontSize(12).fontColor(action === '清除' ? $r('app.color.danger') : $r('app.color.accent'))
        .backgroundColor(action === '清除' ? $r('app.color.danger_surface') : $r('app.color.accent_surface'))
        .borderRadius(15).onClick(onClick)
        .accessibilityText(`${action}${title}`)
    }.width('100%').height(72)
  }

  @Builder
  private NavigationRow(title: string, subtitle: string, onClick: () => void) {
    Row() {
      Column({ space: 4 }) {
        Text(title).fontSize(15).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
        Text(subtitle).fontSize(11).fontColor($r('app.color.text_secondary'))
      }.alignItems(HorizontalAlign.Start)
      Blank()
      Text('›').fontSize(24).fontColor($r('app.color.text_secondary'))
    }.width('100%').height(72).onClick(onClick)
      .accessibilityText(title).accessibilityDescription(`${subtitle}，点按修改`)
  }
}
