/** First-run privacy gate. No network or storage service starts behind it. */
@ComponentV2
export struct PrivacyConsentOverlay {
  @Param onOpenPolicy: () => void = () => {}
  @Param onResolve: (agreed: boolean) => void = (_agreed: boolean) => {}

  build() {
    Column() {
      Column({ space: 14 }) {
        Text('隐私政策提示').fontSize(22).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).width('100%')
        Text('欢迎使用 HM互传。HM互传用于在同一局域网内发现设备并传输文件。为实现设备发现、文件发送、文件接收和历史记录展示，应用会在本地使用设备名称、局域网地址、文件名、文件大小、传输结果和保存位置等信息。')
          .fontSize(14).lineHeight(22).fontColor($r('app.color.text_secondary')).width('100%')
        Text('我们不会将文件或上述信息上传到云端服务器。请阅读并同意隐私政策后继续使用。')
          .fontSize(14).lineHeight(22).fontColor($r('app.color.text_secondary')).width('100%')
        Row() {
          Text('查看').fontSize(14).fontColor($r('app.color.text_secondary'))
          Text('《隐私政策》').fontSize(14).fontWeight(FontWeight.Medium).fontColor('#2563EB')
            .onClick(this.onOpenPolicy)
        }.width('100%')
        Row({ space: 10 }) {
          Button('不同意并退出').layoutWeight(1).height(44).fontSize(15).fontColor('#475569')
            .backgroundColor('#EEF2F7').borderRadius(12).onClick(() => this.onResolve(false))
          Button('同意并继续').layoutWeight(1).height(44).fontSize(15).fontColor('#FFFFFF')
            .backgroundColor('#2563EB').borderRadius(12).onClick(() => this.onResolve(true))
        }.width('100%').margin({ top: 4 })
      }.width('88%').constraintSize({ maxWidth: 520 }).padding({ left: 22, right: 22, top: 22, bottom: 18 })
        .backgroundColor($r('app.color.surface_primary')).borderRadius(20).shadow({ radius: 20, color: '#0000001A', offsetY: 8 })
    }.width('100%').height('100%').justifyContent(FlexAlign.Center).backgroundColor($r('app.color.scrim')).zIndex(20)
  }
}

/** Six-digit pairing dialog; the parent owns validation and persistence. */
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
        Row({ space: 12 }) {
          Button('取消').layoutWeight(1).onClick(this.onCancel)
          Button('配对并连接').layoutWeight(1).enabled(this.input.length === 6).fontColor('#FFFFFF')
            .backgroundColor('#287BCC').onClick(this.onSubmit)
        }.width('100%')
      }.width('80%').constraintSize({ maxWidth: 480 }).padding(24).backgroundColor($r('app.color.surface_primary')).borderRadius(24)
        .shadow({ radius: 24, color: '#18283B33', offsetY: 10 })
    }.width('100%').height('100%').justifyContent(FlexAlign.Center).backgroundColor($r('app.color.scrim')).zIndex(30)
  }
}

/** Edits both ports atomically so the two listeners always restart together. */
@ComponentV2
export struct PortEditorOverlay {
  @Param udpPort: string = '51889'
  @Param tcpPort: string = '51888'
  @Param onUdpChanged: (value: string) => void = (_value: string) => {}
  @Param onTcpChanged: (value: string) => void = (_value: string) => {}
  @Param onCancel: () => void = () => {}
  @Param onSave: () => void = () => {}

  build() {
    Column() {
      Column({ space: 16 }) {
        Text('修改网络端口').fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
        this.PortInput('UDP 发现端口', this.udpPort, '51889', this.onUdpChanged)
        this.PortInput('TCP 传输端口', this.tcpPort, '51888', this.onTcpChanged)
        Text('修改后会重新启动发现与接收服务；两端 UDP 端口需要保持一致。')
          .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
        Row({ space: 12 }) {
          Button('取消').layoutWeight(1).onClick(this.onCancel)
          Button('保存并重启').layoutWeight(1).fontColor('#FFFFFF').backgroundColor('#287BCC').onClick(this.onSave)
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
    }.alignItems(HorizontalAlign.Start).width('100%')
  }
}
