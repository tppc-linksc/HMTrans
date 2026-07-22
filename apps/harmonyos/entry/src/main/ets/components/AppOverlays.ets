/**
 * 所有自绘弹窗共用同一套操作按钮：次要操作跟随系统深浅色，主要操作固定为品牌蓝。
 * 不能依赖 Button 默认强调色，否则 HarmonyOS 会把“取消”也绘制成蓝色主按钮。
 */
@ComponentV2
struct DialogActionButton {
  @Param title: string = ''
  @Param primary: boolean = false
  @Param available: boolean = true
  @Param action: () => void = () => {}

  build() {
    Button(this.title)
      .width('100%').height(44).fontSize(15).fontWeight(FontWeight.Medium)
      .fontColor(this.primary ? '#FFFFFF' : $r('app.color.text_primary'))
      .backgroundColor(this.primary ? $r('app.color.accent_strong') : $r('app.color.control_track'))
      .borderRadius(12).enabled(this.available).onClick(this.action)
  }
}

/** 隐私确认后的启动门；身份、存储和网络服务准备完成前不允许操作主界面。 */
@ComponentV2
export struct InitializationOverlay {
  @Param detail: string = '正在准备本机身份、下载目录和局域网服务'
  @Param failed: boolean = false
  @Param onRetry: () => void = () => {}

  build() {
    Column() {
      Column({ space: 14 }) {
        if (!this.failed) {
          LoadingProgress().width(36).height(36).color($r('app.color.accent_strong'))
        }
        Text(this.failed ? '启动未完成' : '正在启动 HM互传')
          .fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
        Text(this.detail)
          .fontSize(13).lineHeight(20).fontColor($r('app.color.text_secondary')).textAlign(TextAlign.Center)
          .width('100%')
        if (this.failed) {
          DialogActionButton({ title: '重试', primary: true, action: this.onRetry })
        }
      }.width('80%').constraintSize({ maxWidth: 460 }).padding(24)
        .backgroundColor($r('app.color.surface_primary')).borderRadius(20)
        .shadow({ radius: 20, color: '#0000001A', offsetY: 8 })
    }.width('100%').height('100%').justifyContent(FlexAlign.Center)
      .backgroundColor($r('app.color.app_background')).zIndex(19)
  }
}

/** 首次启动隐私门；用户确认前不启动网络或存储服务。 */
@ComponentV2
export struct PrivacyConsentOverlay {
  @Param onOpenPolicy: () => void = () => {}
  @Param onResolve: (agreed: boolean) => void = (_agreed: boolean) => {}

  build() {
    Column() {
      Column({ space: 14 }) {
        Text('隐私政策提示').fontSize(22).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).width('100%')
        Text('欢迎使用 HM互传。HM互传用于在同一局域网内发现设备、传输文件，并可由你主动把 MatePad 屏幕投放到已配对的 Mac。为实现这些功能，应用会在本地使用设备名称、局域网地址、文件名、文件大小、传输结果、保存位置和投屏运行状态等信息。')
          .fontSize(14).lineHeight(22).fontColor($r('app.color.text_secondary')).width('100%')
        Text('投屏每次都需要你主动发起并确认系统屏幕采集授权，画面只在局域网内加密传给已配对 Mac，并仅在内存中显示。我们不会将文件、画面或上述信息上传到云端服务器。请阅读并同意隐私政策后继续使用。')
          .fontSize(14).lineHeight(22).fontColor($r('app.color.text_secondary')).width('100%')
        Row() {
          Text('查看').fontSize(14).fontColor($r('app.color.text_secondary'))
          Text('《隐私政策》').fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.accent_strong'))
            .onClick(this.onOpenPolicy)
            .accessibilityText('查看完整隐私政策')
        }.width('100%')
        Row({ space: 10 }) {
          DialogActionButton({ title: '不同意并退出', action: () => this.onResolve(false) }).layoutWeight(1)
          DialogActionButton({ title: '同意并继续', primary: true,
            action: () => this.onResolve(true) }).layoutWeight(1)
        }.width('100%').margin({ top: 4 })
      }.width('88%').constraintSize({ maxWidth: 520 }).padding({ left: 22, right: 22, top: 22, bottom: 18 })
        .backgroundColor($r('app.color.surface_primary')).borderRadius(20).shadow({ radius: 20, color: '#0000001A', offsetY: 8 })
    }.width('100%').height('100%').justifyContent(FlexAlign.Center).backgroundColor($r('app.color.scrim')).zIndex(20)
  }
}

/** 六位配对码对话框；校验与持久化由父组件负责。 */
@ComponentV2
export struct PairingOverlay {
  @Param deviceName: string = '设备'
  @Param input: string = ''
  @Param onInputChanged: (value: string) => void = (_value: string) => {}
  @Param onCancel: () => void = () => {}
  @Param onSubmit: () => void = () => {}

  build() {
    Column() {
      Column({ space: 14 }) {
        Text(`输入 ${this.deviceName} 的配对码`).fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
        Text('请在对方设备上查看当前六位配对码，校验成功后双方才会保存信任关系。')
          .fontSize(12).fontColor($r('app.color.text_secondary')).textAlign(TextAlign.Center)
        TextInput({ text: this.input, placeholder: '六位配对码' }).type(InputType.Number).maxLength(6).height(48)
          .fontSize(20).textAlign(TextAlign.Center).onChange((value: string) => {
            this.onInputChanged(value.replace(/\D/g, ''))
          })
          .accessibilityText(`${this.deviceName} 的六位配对码`)
          .accessibilityDescription('请从对方设备的连接页面读取')
        Row({ space: 12 }) {
          DialogActionButton({ title: '取消', action: this.onCancel }).layoutWeight(1)
          DialogActionButton({ title: '配对并连接', primary: true, available: this.input.length === 6,
            action: this.onSubmit }).layoutWeight(1)
        }.width('100%')
      }.width('80%').constraintSize({ maxWidth: 480 }).padding(24).backgroundColor($r('app.color.surface_primary')).borderRadius(24)
        .shadow({ radius: 24, color: '#18283B33', offsetY: 10 })
    }.width('100%').height('100%').justifyContent(FlexAlign.Center).backgroundColor($r('app.color.scrim')).zIndex(30)
  }
}

/** 原子修改三个网络端口，确保发现、文件传输和投屏配置始终一起生效。 */
@ComponentV2
export struct PortEditorOverlay {
  @Param udpPort: string = '51889'
  @Param tcpPort: string = '51888'
  @Param castPort: string = '51890'
  @Param onUdpChanged: (value: string) => void = (_value: string) => {}
  @Param onTcpChanged: (value: string) => void = (_value: string) => {}
  @Param onCastChanged: (value: string) => void = (_value: string) => {}
  @Param onCancel: () => void = () => {}
  @Param onSave: () => void = () => {}

  build() {
    Column() {
      Column({ space: 16 }) {
        Text('网络服务端口').fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
        this.PortInput('UDP 发现端口', this.udpPort, '51889', this.onUdpChanged)
        this.PortInput('TCP 传输端口', this.tcpPort, '51888', this.onTcpChanged)
        this.PortInput('TCP 投屏端口', this.castPort, '51890', this.onCastChanged)
        Text('三个端口不能重复。保存后会重新启动发现与接收服务；双端对应端口需要保持一致。')
          .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
        Row({ space: 12 }) {
          DialogActionButton({ title: '取消', action: this.onCancel }).layoutWeight(1)
          DialogActionButton({ title: '保存并重启', primary: true, action: this.onSave }).layoutWeight(1)
        }.width('100%')
      }.width('80%').constraintSize({ maxWidth: 480 }).padding(24).backgroundColor($r('app.color.surface_primary')).borderRadius(24)
        .shadow({ radius: 18, color: '#18283B29', offsetY: 8 })
    }.width('100%').height('100%').justifyContent(FlexAlign.Center).backgroundColor($r('app.color.scrim')).zIndex(31)
  }

  @Builder
  private PortInput(label: string, value: string, placeholder: string, onChange: (value: string) => void) {
    Column({ space: 6 }) {
      Text(label).fontSize(13).fontWeight(FontWeight.Medium).width('100%')
      TextInput({ text: value, placeholder }).type(InputType.Number).maxLength(5).height(46)
        .onChange((next: string) => onChange(next.replace(/\D/g, '')))
        .accessibilityText(label)
    }.alignItems(HorizontalAlign.Start).width('100%')
  }
}

/** 投屏设置按真机 H.264 硬件能力选择分辨率与帧率。 */
@ComponentV2
export struct CastSettingsOverlay {
  @Param resolution: string = '1080p'
  @Param frameRate: number = 60
  @Param supportedModes: Array<string> = []
  @Param onResolutionChanged: (value: string) => void = (_value: string) => {}
  @Param onFrameRateChanged: (value: number) => void = (_value: number) => {}
  @Param onCancel: () => void = () => {}
  @Param onSave: () => void = () => {}

  build() {
    Column() {
      Column({ space: 16 }) {
        Text('投屏设置').fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
        Column({ space: 8 }) {
          Text('清晰度').fontSize(13).fontWeight(FontWeight.Medium).width('100%')
          Row({ space: 8 }) {
            this.ResolutionButton('720P 级', '720p')
            this.ResolutionButton('1080P 级', '1080p')
            this.ResolutionButton('2K 级', '2k')
          }.width('100%')
        }.alignItems(HorizontalAlign.Start).width('100%')
        Column({ space: 8 }) {
          Text('帧率').fontSize(13).fontWeight(FontWeight.Medium).width('100%')
          Row({ space: 8 }) {
            this.FrameRateButton('30P', 30)
            this.FrameRateButton('60P', 60)
          }.width('100%')
        }.alignItems(HorizontalAlign.Start).width('100%')
        Text('可选组合来自当前真机 H.264 硬件编码能力。为保持 Pad 屏幕比例，实际尺寸依次为 1280×840、1920×1260、2560×1680。当前稳定实现最高为 2K 级 / 60P，暂不开放 4K、90P、120P。')
          .fontSize(11).lineHeight(17).fontColor($r('app.color.text_secondary')).width('100%')
        Row({ space: 12 }) {
          DialogActionButton({ title: '取消', action: this.onCancel }).layoutWeight(1)
          DialogActionButton({ title: '保存', primary: true,
            available: this.modeSupported(this.resolution, this.frameRate), action: this.onSave }).layoutWeight(1)
        }.width('100%')
      }.width('80%').constraintSize({ maxWidth: 480 }).padding(24)
        .backgroundColor($r('app.color.surface_primary')).borderRadius(24)
        .shadow({ radius: 18, color: '#18283B29', offsetY: 8 })
    }.width('100%').height('100%').justifyContent(FlexAlign.Center)
      .backgroundColor($r('app.color.scrim')).zIndex(32)
  }

  @Builder
  private ResolutionButton(title: string, value: string) {
    Button(title).layoutWeight(1).height(38).fontSize(13)
      .fontColor(this.resolution === value ? '#FFFFFF' : $r('app.color.text_primary'))
      .backgroundColor(this.resolution === value ? $r('app.color.accent') : $r('app.color.control_track'))
      .borderRadius(10).enabled(this.resolutionAvailable(value)).opacity(this.resolutionAvailable(value) ? 1 : 0.45)
      .onClick(() => this.onResolutionChanged(value))
      .accessibilityDescription(this.resolution === value ? '当前已选择' :
        this.resolutionAvailable(value) ? '点按选择' : '当前设备不支持')
  }

  @Builder
  private FrameRateButton(title: string, value: number) {
    Button(title).layoutWeight(1).height(38).fontSize(13)
      .fontColor(this.frameRate === value ? '#FFFFFF' : $r('app.color.text_primary'))
      .backgroundColor(this.frameRate === value ? $r('app.color.accent') : $r('app.color.control_track'))
      .borderRadius(10).enabled(this.modeSupported(this.resolution, value))
      .opacity(this.modeSupported(this.resolution, value) ? 1 : 0.45)
      .onClick(() => this.onFrameRateChanged(value))
      .accessibilityDescription(this.frameRate === value ? '当前已选择' :
        this.modeSupported(this.resolution, value) ? '点按选择' : '当前设备不支持')
  }

  private resolutionAvailable(value: string): boolean {
    return this.modeSupported(value, 30) || this.modeSupported(value, 60)
  }

  private modeSupported(resolution: string, frameRate: number): boolean {
    return this.supportedModes.indexOf(`${resolution}@${frameRate}`) >= 0
  }
}

/** 网络测试必须把可用性结论、原始指标和处理建议完整呈现，不能只依赖短暂 Toast。 */
@ComponentV2
export struct NetworkTestResultOverlay {
  @Param state: string = 'idle'
  @Param targetName: string = 'Mac'
  @Param throughputMbps: number = 0
  @Param averageRttMs: number = 0
  @Param jitterMs: number = 0
  @Param recommendation: string = ''
  @Param detail: string = ''
  @Param guidance: string = ''
  @Param onClose: () => void = () => {}
  @Param onRetry: () => void = () => {}

  build() {
    Column() {
      Column({ space: 16 }) {
        Text('投屏网络测试').fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Column({ space: 5 }) {
          Text(this.resultTitle()).fontSize(17).fontWeight(FontWeight.Bold)
            .fontColor(this.resultTitleColor())
          Text(this.resultSubtitle())
            .fontSize(12).lineHeight(18).fontColor($r('app.color.text_secondary')).textAlign(TextAlign.Center)
        }.width('100%')
        if (this.state === 'idle') {
          Column({ space: 7 }) {
            Text('测试内容').fontSize(12).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
            Text('• 平均延迟与网络抖动\n• Pad 到 Mac 的实际上行吞吐\n• 可用性结论和推荐投屏参数')
              .fontSize(12).lineHeight(19).fontColor($r('app.color.text_secondary'))
            Text('测试只发送约 32 MB 内存数据，不访问公网，也不会保存文件。')
              .fontSize(11).lineHeight(17).fontColor($r('app.color.text_secondary'))
          }.alignItems(HorizontalAlign.Start).width('100%').padding(14)
            .backgroundColor($r('app.color.control_track')).borderRadius(12)
        } else if (this.state === 'running') {
          Column({ space: 10 }) {
            LoadingProgress().width(36).height(36).color($r('app.color.accent_strong'))
            Text('通常需要数秒，请保持双端应用运行且网络连接稳定。')
              .fontSize(11).lineHeight(17).fontColor($r('app.color.text_secondary')).textAlign(TextAlign.Center)
          }.width('100%')
        } else if (this.state === 'completed') {
          Row({ space: 8 }) {
            this.MetricCard('上行吞吐', `${this.throughputMbps.toFixed(1)} Mbps`)
            this.MetricCard('平均延迟', `${this.averageRttMs.toFixed(1)} ms`)
            this.MetricCard('网络抖动', `${this.jitterMs.toFixed(1)} ms`)
          }.width('100%')
          Column({ space: 6 }) {
            Text('建议投屏参数').fontSize(12).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
            Text(this.recommendation).fontSize(13).lineHeight(19).fontColor($r('app.color.text_primary'))
          }.alignItems(HorizontalAlign.Start).width('100%').padding(14)
            .backgroundColor($r('app.color.accent_surface')).borderRadius(12)
        }
        if (this.state === 'completed' || this.state === 'failed') {
          Column({ space: 6 }) {
            Text(this.state === 'completed' ? '使用建议' : '请按以下步骤检查')
              .fontSize(12).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
            Text(this.guidance).fontSize(12).lineHeight(19).fontColor($r('app.color.text_secondary'))
          }.alignItems(HorizontalAlign.Start).width('100%')
        }
        Row({ space: 12 }) {
          DialogActionButton({ title: this.state === 'idle' ? '取消' : '关闭',
            available: this.state !== 'running', action: this.onClose }).layoutWeight(1)
          DialogActionButton({ title: this.testButtonTitle(), primary: true,
            available: this.state !== 'running', action: this.onRetry }).layoutWeight(1)
        }.width('100%')
      }.width('84%').constraintSize({ maxWidth: 560 }).padding(24)
        .backgroundColor($r('app.color.surface_primary')).borderRadius(24)
        .shadow({ radius: 18, color: '#18283B29', offsetY: 8 })
    }.width('100%').height('100%').justifyContent(FlexAlign.Center)
      .backgroundColor($r('app.color.scrim')).zIndex(33)
  }

  @Builder
  private MetricCard(label: string, value: string) {
    Column({ space: 5 }) {
      Text(value).fontSize(14).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
      Text(label).fontSize(10).fontColor($r('app.color.text_secondary'))
    }.layoutWeight(1).height(66).justifyContent(FlexAlign.Center)
      .backgroundColor($r('app.color.control_track')).borderRadius(11)
  }

  private resultTitle(): string {
    if (this.state === 'idle') return '先测试，再选择合适的投屏参数'
    if (this.state === 'running') return '正在测试当前投屏链路'
    if (this.state === 'failed') return '测试失败，当前无法判断投屏质量'
    if (this.throughputMbps >= 25 && this.averageRttMs <= 80 && this.jitterMs <= 30) return '网络可用，可以投屏'
    if (this.throughputMbps >= 12) return '网络勉强可用，建议降低画质'
    return '网络较弱，不建议当前直接投屏'
  }

  private resultSubtitle(): string {
    if (this.state === 'idle') return '将测试当前选中的已连接 Mac；未选择时会自动使用唯一连接设备。'
    if (this.state === 'completed') return `Pad → ${this.targetName} 的实际投屏链路`
    return this.detail
  }

  private resultTitleColor(): ResourceColor {
    if (this.state === 'completed') return $r('app.color.success')
    if (this.state === 'failed') return $r('app.color.danger')
    return $r('app.color.accent_strong')
  }

  private testButtonTitle(): string {
    if (this.state === 'idle') return '开始测试'
    if (this.state === 'running') return '测试中'
    return '重新测试'
  }
}
