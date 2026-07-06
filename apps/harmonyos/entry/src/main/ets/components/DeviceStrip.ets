import { DeviceInfo } from '../common/Protocol'

@ComponentV2
export struct DeviceStrip {
  @Param devices: Array<DeviceInfo> = []
  @Param selectedDeviceId: string = ''
  @Param onDeviceSelected: (device: DeviceInfo) => void = (_device: DeviceInfo) => {}

  build() {
    Column({ space: 10 }) {
      Row() {
        Text('附近设备')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#0F172A')
        Blank()
        Text(this.devices.length > 0 ? `${this.devices.length} 台` : '搜索中')
          .fontSize(12)
          .fontColor('#64748B')
      }
      .width('100%')

      if (this.devices.length === 0) {
        Row() {
          Blank()
          this.EmptyDeviceCard()
          Blank()
        }
        .width('100%')
        .height(66)
      } else {
        Scroll() {
          Row({ space: 10 }) {
            Repeat<DeviceInfo>(this.devices)
              .each((repeatItem) => {
                this.DeviceCard(repeatItem.item)
              })
              .key((device: DeviceInfo) => device.deviceId)
          }
          .width('100%')
          .justifyContent(FlexAlign.Start)
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .height(66)
      }
    }
    .height(116)
    .padding(12)
    .backgroundColor('#FBFEFF')
    .borderRadius(18)
    .border({ width: 1, color: '#D8EAFB' })
    .shadow({ radius: 22, color: '#E4EEF8', offsetY: 10 })
  }

  @Builder
  private DeviceIcon(platform: string) {
    Image(platform === 'macOS' ? $r('app.media.device_macbook') : $r('app.media.device_matepad'))
      .width(42)
      .height(42)
      .borderRadius(12)
  }

  @Builder
  private EmptyDeviceCard() {
    Row({ space: 10 }) {
      Image($r('app.media.icon_wifi_discovery'))
        .width(42)
        .height(42)
        .backgroundColor('#F8FCFF')
        .borderRadius(12)
      Column({ space: 3 }) {
        Text('正在搜索 Mac')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor('#172033')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('保持 Mac 端 HMTrans 打开')
          .fontSize(11)
          .fontColor('#64748B')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
    }
    .width(190)
    .height(58)
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .backgroundColor('#F7FCFF')
    .borderRadius(16)
  }

  @Builder
  private DeviceCard(device: DeviceInfo) {
    Row({ space: 10 }) {
      this.DeviceIcon(device.platform)
      Column({ space: 3 }) {
        Text(device.deviceName)
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor('#172033')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(device.platform)
          .fontSize(10)
          .fontColor('#64748B')
        Text(device.ip)
          .fontSize(10)
          .fontColor('#64748B')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text(this.selectedDeviceId === device.deviceId ? '✓' : '›')
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.selectedDeviceId === device.deviceId ? '#16A34A' : '#2563EB')
    }
    .width(174)
    .height(58)
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .backgroundColor(this.selectedDeviceId === device.deviceId ? '#EEF8FF' : '#F7FCFF')
    .borderRadius(16)
    .border({
      width: this.selectedDeviceId === device.deviceId ? 1 : 0,
      color: '#3B82F6',
    })
    .onClick(() => {
      this.onDeviceSelected(device)
    })
  }
}
