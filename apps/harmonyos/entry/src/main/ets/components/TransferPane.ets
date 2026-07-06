import { TransferListItem } from '../models/TransferListItem'

@ComponentV2
export struct TransferPane {
  @Param title: string = ''
  @Param iconKind: string = ''
  @Param items: Array<TransferListItem> = []
  @Param emptyTitle: string = ''
  @Param emptySubtitle: string = ''
  @Param compactLayout: boolean = false

  build() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        this.PaneIcon(this.iconKind)
        Text(this.title)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#172033')
        Blank()
        Text(`${this.items.length}`)
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor('#64748B')
          .textAlign(TextAlign.Center)
          .width(28)
          .height(28)
          .backgroundColor('#EEF6FD')
          .borderRadius(14)
      }
      .width('100%')

      this.TransferList()
    }
    .width(this.compactLayout ? '100%' : '49%')
    .constraintSize({ minWidth: 320, minHeight: 360 })
    .margin({ bottom: 14 })
    .padding(16)
    .backgroundColor('#FBFEFF')
    .borderRadius(22)
    .border({ width: 1, color: '#D8EAFB' })
    .shadow({ radius: 24, color: '#E4EEF8', offsetY: 10 })
  }

  @Builder
  private PaneIcon(kind: string) {
    Image(kind === 'history' ? $r('app.media.icon_history_record') : $r('app.media.icon_transfer_current'))
      .width(20)
      .height(20)
  }

  @Builder
  private EmptyTransferIcon() {
    Image($r('app.media.icon_transfer_empty'))
      .width(48)
      .height(48)
      .padding(9)
      .backgroundColor('#F8FCFF')
      .borderRadius(12)
  }

  @Builder
  private FileDirectionIcon(direction: string) {
    Image(direction === '发送' ? $r('app.media.icon_file_send') : $r('app.media.icon_file_receive'))
      .width(24)
      .height(24)
      .padding(10)
      .backgroundColor('#F8FCFF')
      .borderRadius(12)
  }

  @Builder
  private TransferList() {
    if (this.items.length === 0) {
      Column({ space: 10 }) {
        this.EmptyTransferIcon()
        Text(this.emptyTitle)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#172033')
          .textAlign(TextAlign.Center)
          .maxLines(2)
          .width('90%')
        Text(this.emptySubtitle)
          .fontSize(12)
          .fontColor('#64748B')
          .textAlign(TextAlign.Center)
          .maxLines(3)
          .width('90%')
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor('#FBFEFF')
      .borderRadius(16)
    } else {
      Scroll() {
        Column({ space: 8 }) {
          Repeat<TransferListItem>(this.items)
            .each((repeatItem) => {
              this.TransferRow(repeatItem.item)
            })
            .key((item: TransferListItem) => item.id)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Start)
        .alignItems(HorizontalAlign.Start)
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .layoutWeight(1)
    }
  }

  @Builder
  private TransferRow(item: TransferListItem) {
    Row({ space: 12 }) {
      this.FileDirectionIcon(item.direction)

      Column({ space: 6 }) {
        Row() {
          Text(item.fileName)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#172033')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Blank()
          Text(item.state)
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor(item.state === '失败' ? '#EF4444' : item.state === '已完成' ? '#16A34A' : '#2563EB')
            .maxLines(1)
        }
        .width('100%')

        Row() {
          Text(`${item.direction} · ${item.peerName}`)
            .fontSize(11)
            .fontColor('#64748B')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Blank()
          Text(item.timeText)
            .fontSize(11)
            .fontColor('#64748B')
        }
        .width('100%')

        Progress({ value: item.progress, total: 100, type: ProgressType.Linear })
          .width('100%')
          .height(4)
          .color('#2563EB')

        Text(item.detail)
          .fontSize(11)
          .fontColor('#64748B')
          .textAlign(TextAlign.Start)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
    }
    .width('100%')
    .padding(10)
    .backgroundColor('#F7FCFF')
    .borderRadius(16)
  }
}
