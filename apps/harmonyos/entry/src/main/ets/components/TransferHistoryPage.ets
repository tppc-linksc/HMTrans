import { TransferListItem, TransferState } from '../models/TransferListItem'

/** 统一展示当前任务与历史记录，任务变更交由上层处理。 */
@ComponentV2
export struct TransferHistoryPage {
  @Param currentTransfers: Array<TransferListItem> = []
  @Param historyTransfers: Array<TransferListItem> = []
  @Param historyFilter: string = 'all'
  @Param compactLayout: boolean = false
  @Param onFilterChanged: (value: string) => void = (_value: string) => {}
  @Param onTogglePause: (item: TransferListItem) => void = (_item: TransferListItem) => {}
  @Param onCancel: (item: TransferListItem) => void = (_item: TransferListItem) => {}
  @Param onToggleGroup: (item: TransferListItem) => void = (_item: TransferListItem) => {}
  @Param onCancelGroup: (item: TransferListItem) => void = (_item: TransferListItem) => {}
  @Param onDeleteHistory: (item: TransferListItem) => void = (_item: TransferListItem) => {}
  @Param onRetryHistory: (item: TransferListItem) => void = (_item: TransferListItem) => {}
  @Param onClearPeer: (deviceKey: string, peerName: string) => void = (_deviceKey: string, _peerName: string) => {}
  @Param onClearAll: () => void = () => {}

  build() {
    Column({ space: 14 }) {
      this.HistoryContent()
    }
    .width('100%')
  }

  @Builder
  private HistoryContent() {
    Row() {
      Row({ space: 0 }) {
        this.FilterButton('全部', 'all')
        this.FilterButton('传输中', 'current')
        this.FilterButton('已完成', 'done')
        this.FilterButton('失败', 'failed')
        this.FilterButton('已取消', 'cancelled')
      }
      .width(this.compactLayout ? 296 : 496).height(42).padding(3)
      .backgroundColor($r('app.color.control_track')).borderRadius(12)
      Blank()
      Text('清空记录').fontSize(11).fontWeight(FontWeight.Medium).fontColor($r('app.color.danger'))
        .height(36).padding({ left: 10, right: 4 }).textAlign(TextAlign.Center)
        .opacity(this.historyTransfers.length > 0 ? 1 : 0.4)
        .onClick(() => { if (this.historyTransfers.length > 0) this.onClearAll() })
        .accessibilityText('清空全部历史记录')
    }.width('100%')
    if (this.filteredGroupKeys().length === 0) {
      Column({ space: 10 }) {
        Image($r('app.media.icon_transfer_empty')).width(48).height(48)
        Text('暂无匹配的传输记录').fontSize(16).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
        Text('正在传输和已结束的任务都会按设备保存在本机').fontSize(12).fontColor($r('app.color.text_secondary'))
      }.width('100%').height(360).justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.surface_primary')).borderRadius(22)
        .border({ width: 1, color: $r('app.color.border_subtle') })
    } else {
      Repeat<string>(this.filteredGroupKeys())
        .each((item) => { this.DeviceGroup(item.item) })
        .key((deviceKey: string) => deviceKey)
    }
  }

  @Builder
  private DeviceGroup(deviceKey: string) {
    Column({ space: 10 }) {
      Row() {
        Image($r('app.media.device_macbook')).width(34).height(30).borderRadius(9)
        Text(this.groupName(deviceKey)).fontSize(13).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary')).margin({ left: 9 })
        Blank()
        Text(`${this.itemsForGroup(deviceKey).length} 条记录`).fontSize(10).fontColor($r('app.color.text_secondary'))
        Text('清空本设备记录').fontSize(10).fontWeight(FontWeight.Medium).fontColor($r('app.color.danger'))
          .height(34).padding({ left: 12, right: 2 }).textAlign(TextAlign.Center)
          .opacity(this.historyItemsForGroup(deviceKey).length > 0 ? 1 : 0.45)
          .onClick(() => {
            if (this.historyItemsForGroup(deviceKey).length > 0) {
              this.onClearPeer(deviceKey, this.groupName(deviceKey))
            }
          })
          .accessibilityText(`清空 ${this.groupName(deviceKey)} 的历史记录`)
      }.width('100%')
      List({ space: 0 }) {
        Repeat<TransferListItem>(this.itemsForGroup(deviceKey))
          .each((item) => { this.HistoryListItem(item.item) })
          .key((item: TransferListItem) => item.id)
      }
      .width('100%').height(this.itemsForGroup(deviceKey).length * 68)
      .scrollBar(BarState.Off).backgroundColor($r('app.color.surface_primary'))
      .borderRadius(14).border({ width: 1, color: $r('app.color.border_subtle') }).clip(true)
    }
    .width('100%').padding(14).backgroundColor($r('app.color.surface_primary'))
    .borderRadius(18).border({ width: 1, color: $r('app.color.border_subtle') })
  }

  /** 触摸列表通过原生左滑手势提供历史记录的删除操作。 */
  @Builder
  private HistoryListItem(item: TransferListItem) {
    if (this.isCurrent(item)) {
      ListItem() {
        this.HistoryRow(item)
      }
    } else {
      ListItem() {
        this.HistoryRow(item)
      }
      .swipeAction({
        end: {
          builder: () => { this.SwipeDeleteAction(item) },
          actionAreaDistance: 64,
          onAction: () => this.onDeleteHistory(item),
        },
        edgeEffect: SwipeEdgeEffect.Spring,
      })
      .onClick(() => this.retryIfAvailable(item))
    }
  }

  @Builder
  private SwipeDeleteAction(item: TransferListItem) {
    Stack() {
      Image($r('app.media.icon_delete')).width(22).height(22)
    }
    .width(64).height('100%').backgroundColor($r('app.color.danger'))
    .onClick(() => this.onDeleteHistory(item))
    .accessibilityText(`删除 ${item.fileName} 的传输记录`)
  }

  @Builder
  private HistoryRow(item: TransferListItem) {
    Row({ space: 12 }) {
      Text(item.fileType.length > 0 ? item.fileType : 'FILE').fontSize(9).fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.accent_strong')).width(42).height(42).textAlign(TextAlign.Center)
        .backgroundColor($r('app.color.accent_surface')).borderRadius(11)
      Column({ space: 4 }) {
        Text(item.fileName).fontSize(13).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).maxLines(1)
        Text(`${item.direction} · ${item.timeText} · ${item.detail}`).fontSize(10).fontColor($r('app.color.text_secondary')).maxLines(1)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text(this.stateLabel(item)).fontSize(10).fontWeight(FontWeight.Bold)
        .fontColor(item.state === TransferState.Failed ? $r('app.color.danger') :
          item.state === TransferState.Done ? $r('app.color.success') : $r('app.color.accent'))
      if (this.isCurrent(item)) {
        Button(item.state === TransferState.Paused || item.state === TransferState.Waiting ? '继续' : '暂停')
          .height(36).padding({ left: 14, right: 14 }).fontSize(10).fontColor($r('app.color.accent_strong'))
          .backgroundColor($r('app.color.accent_soft_surface')).borderRadius(18).onClick(() => this.onTogglePause(item))
          .accessibilityDescription(`${item.fileName}，${item.state}`)
        Button('取消')
          .height(36).padding({ left: 14, right: 14 }).fontSize(10).fontColor($r('app.color.danger'))
          .backgroundColor($r('app.color.danger_surface')).borderRadius(18).onClick(() => this.onCancel(item))
      }
    }.width('100%').height(68).padding({ left: 14, right: 14 })
  }

  @Builder
  private FilterButton(label: string, value: string) {
    Button(label).width(this.compactLayout ? 58 : 98).height(36).fontSize(this.compactLayout ? 10 : 12)
      .fontWeight(this.historyFilter === value ? FontWeight.Bold : FontWeight.Medium)
      .fontColor(this.historyFilter === value ? '#FFFFFF' : $r('app.color.text_secondary'))
      .backgroundColor(this.historyFilter === value ? $r('app.color.accent') : Color.Transparent).borderRadius(9)
      .onClick(() => this.onFilterChanged(value))
      .accessibilityDescription(`仅显示${label}的传输记录`)
  }

  private retryIfAvailable(item: TransferListItem): void {
    if (item.direction === '发送' && (item.state === TransferState.Failed || item.state === TransferState.Cancelled)) {
      this.onRetryHistory(item)
    }
  }

  private stateLabel(item: TransferListItem): string {
    if (item.direction === '发送' && (item.state === TransferState.Failed || item.state === TransferState.Cancelled)) {
      return `${item.state} · 点按重试`
    }
    return item.state
  }

  private filteredItems(): Array<TransferListItem> {
    if (this.historyFilter === 'current') return this.currentTransfers
    if (this.historyFilter === 'done') return this.historyTransfers.filter((item) => item.state === TransferState.Done)
    if (this.historyFilter === 'failed') return this.historyTransfers.filter((item) => item.state === TransferState.Failed)
    if (this.historyFilter === 'cancelled') {
      return this.historyTransfers.filter((item) => item.state === TransferState.Cancelled)
    }
    return this.currentTransfers.concat(this.historyTransfers)
  }

  private filteredGroupKeys(): Array<string> {
    const keys: Array<string> = []
    this.filteredItems().forEach((item) => {
      const key = this.deviceKey(item)
      if (keys.indexOf(key) < 0) keys.push(key)
    })
    return keys.sort((left, right) => (this.itemsForGroup(right)[0]?.updatedAt ?? 0) -
      (this.itemsForGroup(left)[0]?.updatedAt ?? 0))
  }

  private itemsForGroup(deviceKey: string): Array<TransferListItem> {
    return this.filteredItems().filter((item) => this.deviceKey(item) === deviceKey)
      .sort((left, right) => right.updatedAt - left.updatedAt)
  }

  private historyItemsForGroup(deviceKey: string): Array<TransferListItem> {
    return this.historyTransfers.filter((item: TransferListItem) => this.deviceKey(item) === deviceKey)
  }

  private deviceKey(item: TransferListItem): string {
    return item.deviceId.length > 0 ? item.deviceId : `name:${item.peerName}`
  }

  private groupName(deviceKey: string): string {
    const items = this.itemsForGroup(deviceKey)
    if (items.length > 0) return items[0].peerName
    const history = this.historyItemsForGroup(deviceKey)
    return history.length > 0 ? history[0].peerName : '未知设备'
  }

  private isCurrent(item: TransferListItem): boolean {
    return this.currentTransfers.some((row: TransferListItem) => row.id === item.id)
  }
}
