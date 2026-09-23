import { TransferDirection, TransferListItem, TransferState } from '../models/TransferListItem'

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
  // 手机端的多选删除：三层“清空”合并成“选中范围 + 一次删除”，选中态由页面持有，
  // 因为底部操作栏必须画在 Dock 的位置上，只有 Index 能顶掉悬浮 Dock。
  @Param selectionMode: boolean = false
  @Param selectedIds: Array<string> = []
  @Param onEnterSelection: (id: string) => void = (_id: string) => {}
  @Param onToggleSelection: (id: string) => void = (_id: string) => {}
  @Param onToggleGroupSelection: (ids: Array<string>) => void = (_ids: Array<string>) => {}
  @Param onExitSelection: () => void = () => {}

  build() {
    Column({ space: 14 }) {
      this.HistoryContent()
    }
    .width('100%')
  }

  @Builder
  private HistoryContent() {
    if (this.compactLayout) {
      this.CompactToolbar()
    } else {
      this.Toolbar()
    }
    if (this.filteredGroupKeys().length === 0) {
      Column({ space: 10 }) {
        Image($r('app.media.icon_transfer_empty')).width(48).height(48)
        Text('暂无匹配的传输记录').fontSize(16).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
        Text('正在传输和已结束的任务都会按设备保存在本机')
          .fontSize(this.compactLayout ? 13 : 12).fontColor($r('app.color.text_secondary'))
      }.width('100%').height(360).justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.surface_primary')).borderRadius(22)
        .border({ width: 1, color: $r('app.color.border_subtle') })
    } else {
      Repeat<string>(this.filteredGroupKeys())
        .each((item) => { this.DeviceGroup(item.item) })
        .key((deviceKey: string) => deviceKey)
    }
  }

  /** 桌面/平板保留原有文字按钮布局，横向空间充裕，不需要为标签栏腾地方。 */
  @Builder
  private Toolbar() {
    Row() {
      Row({ space: 0 }) {
        this.FilterButton('全部', 'all')
        this.FilterButton('传输中', 'current')
        this.FilterButton('已完成', 'done')
        this.FilterButton('失败', 'failed')
        this.FilterButton('已取消', 'cancelled')
      }
      .width(496).height(42).padding(3)
      .backgroundColor($r('app.color.control_track')).borderRadius(12)
      Blank()
      Text('清空记录').fontSize(11).fontWeight(FontWeight.Medium).fontColor($r('app.color.danger'))
        .height(36).padding({ left: 10, right: 4 }).textAlign(TextAlign.Center)
        .opacity(this.historyTransfers.length > 0 ? 1 : 0.4)
        .onClick(() => { if (this.historyTransfers.length > 0) this.onClearAll() })
        .accessibilityText('清空全部历史记录')
    }.width('100%')
  }

  /**
   * 手机宽度下，五个文字标签挤在固定宽度里字号被迫压到 10sp；改为让标签栏撑满剩余
   * 宽度、每个标签平分空间，字号才能提到与正文一致的档位。删除入口不再常驻在这里，
   * 改由长按进入多选模式承载，页面平时不出现任何红色按钮。
   */
  @Builder
  private CompactToolbar() {
    Row({ space: 8 }) {
      Row({ space: 0 }) {
        this.FilterButton('全部', 'all')
        this.FilterButton('传输中', 'current')
        this.FilterButton('已完成', 'done')
        this.FilterButton('失败', 'failed')
        this.FilterButton('已取消', 'cancelled')
      }
      .layoutWeight(1).height(42).padding(3)
      .backgroundColor($r('app.color.control_track')).borderRadius(12)
      if (this.selectionMode) {
        Text('取消').fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.accent'))
          .height(36).padding({ left: 8, right: 2 }).textAlign(TextAlign.Center)
          .onClick(() => this.onExitSelection())
          .accessibilityText('退出多选')
      }
    }.width('100%')
  }

  @Builder
  private DeviceGroup(deviceKey: string) {
    Column({ space: 10 }) {
      if (this.compactLayout) {
        this.CompactDeviceGroupHeader(deviceKey)
      } else {
        this.DeviceGroupHeader(deviceKey)
      }
      List({ space: 0 }) {
        Repeat<TransferListItem>(this.itemsForGroup(deviceKey))
          .each((item) => { this.HistoryListItem(item.item) })
          .key((item: TransferListItem) => item.id)
      }
      .width('100%').height(this.itemsForGroup(deviceKey).length * 68)
      // 分组 List 与内容等高，只负责 ListItem 的左滑删除，不应抢占外层页面的纵向滚动。
      // 两个方向都让父 Scroll 优先消费手势，避免手指落在历史条目上时内层 List 原地回弹。
      .nestedScroll({
        scrollForward: NestedScrollMode.PARENT_FIRST,
        scrollBackward: NestedScrollMode.PARENT_FIRST,
      })
      .edgeEffect(EdgeEffect.None, { alwaysEnabled: false })
      .scrollBar(BarState.Off).backgroundColor($r('app.color.surface_primary'))
      .borderRadius(14).border({ width: 1, color: $r('app.color.border_subtle') }).clip(true)
    }
    .width('100%').padding(14).backgroundColor($r('app.color.surface_primary'))
    .borderRadius(18).border({ width: 1, color: $r('app.color.border_subtle') })
  }

  @Builder
  private DeviceGroupHeader(deviceKey: string) {
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
  }

  /**
   * 手机宽度下标题只保留设备名和条数；“清空本设备”不再是常驻按钮，而是多选模式里
   * 的一次全选行为，语义和单条删除、全部删除统一到同一套模型上。
   */
  @Builder
  private CompactDeviceGroupHeader(deviceKey: string) {
    Row({ space: 8 }) {
      Image($r('app.media.device_macbook')).width(32).height(28).borderRadius(8)
      Text(this.groupName(deviceKey)).fontSize(15).fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary')).layoutWeight(1).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(`${this.itemsForGroup(deviceKey).length} 条`).fontSize(11).fontColor($r('app.color.text_secondary'))
      if (this.selectionMode && this.selectableIdsForGroup(deviceKey).length > 0) {
        Text(this.isGroupFullySelected(deviceKey) ? '取消全选' : '全选')
          .fontSize(12).fontWeight(FontWeight.Medium).fontColor($r('app.color.accent'))
          .height(28).padding({ left: 8, right: 2 })
          .onClick(() => this.onToggleGroupSelection(this.selectableIdsForGroup(deviceKey)))
          .accessibilityText(`${this.isGroupFullySelected(deviceKey) ? '取消全选' : '全选'} ${this.groupName(deviceKey)} 的记录`)
      }
    }.width('100%')
  }

  /**
   * 触摸列表保留左滑删除单条的快捷路径；长按进入多选，多选期间点按变成勾选，
   * 左滑关闭，避免两种删除手势在同一行上互相抢。进行中的任务不可勾选。
   */
  @Builder
  private HistoryListItem(item: TransferListItem) {
    if (this.selectionMode) {
      ListItem() {
        this.HistoryRow(item)
      }
      .onClick(() => { if (!this.isCurrent(item)) this.onToggleSelection(item.id) })
    } else if (this.isCurrent(item)) {
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
      .gesture(
        LongPressGesture({ repeat: false, duration: 500 })
          .onAction(() => { if (this.compactLayout) this.onEnterSelection(item.id) })
      )
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
      if (this.selectionMode) {
        this.SelectionCheckbox(item)
      }
      Text(item.fileType.length > 0 ? item.fileType : 'FILE')
        .fontSize(this.compactLayout ? 10 : 9).fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.accent_strong')).width(42).height(42).textAlign(TextAlign.Center)
        .backgroundColor($r('app.color.accent_surface')).borderRadius(11)
      Column({ space: 4 }) {
        Text(item.fileName).fontSize(this.compactLayout ? 15 : 13).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary')).maxLines(1)
        Text(`${item.direction} · ${item.timeText} · ${item.detail}`)
          .fontSize(this.compactLayout ? 12 : 10).fontColor($r('app.color.text_secondary')).maxLines(1)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text(this.stateLabel(item)).fontSize(this.compactLayout ? 11 : 10).fontWeight(FontWeight.Bold)
        .fontColor(item.state === TransferState.Failed ? $r('app.color.danger') :
          item.state === TransferState.Done ? $r('app.color.success') : $r('app.color.accent'))
      if (this.isCurrent(item)) {
        Button(item.state === TransferState.Paused || item.state === TransferState.Waiting ? '继续' : '暂停')
          .height(36).padding({ left: 14, right: 14 }).fontSize(this.compactLayout ? 12 : 10)
          .fontColor($r('app.color.accent_strong'))
          .backgroundColor($r('app.color.accent_soft_surface')).borderRadius(18).onClick(() => this.onTogglePause(item))
          .accessibilityDescription(`${item.fileName}，${item.state}`)
        Button('取消')
          .height(36).padding({ left: 14, right: 14 }).fontSize(this.compactLayout ? 12 : 10)
          .fontColor($r('app.color.danger'))
          .backgroundColor($r('app.color.danger_surface')).borderRadius(18).onClick(() => this.onCancel(item))
      }
    }.width('100%').height(68).padding({ left: 14, right: 14 })
    .backgroundColor(this.selectionMode && this.isSelected(item.id) ?
      $r('app.color.accent_soft_surface') : Color.Transparent)
  }

  @Builder
  private SelectionCheckbox(item: TransferListItem) {
    Stack() {
      if (this.isSelected(item.id)) {
        Text('✓').fontSize(12).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
      }
    }
    .width(22).height(22).borderRadius(11)
    .backgroundColor(this.isSelected(item.id) ? $r('app.color.accent_strong') : Color.Transparent)
    .border({ width: this.isSelected(item.id) ? 0 : 1.5, color: $r('app.color.divider') })
    // 进行中的任务只能暂停或取消，不进入批量删除的范围。
    .opacity(this.isCurrent(item) ? 0.25 : 1)
  }

  private isSelected(id: string): boolean {
    return this.selectedIds.indexOf(id) >= 0
  }

  /** 分组里可被批量删除的记录：进行中的任务不算。 */
  private selectableIdsForGroup(deviceKey: string): Array<string> {
    return this.itemsForGroup(deviceKey).filter((row: TransferListItem) => !this.isCurrent(row))
      .map((row: TransferListItem) => row.id)
  }

  private isGroupFullySelected(deviceKey: string): boolean {
    const ids = this.selectableIdsForGroup(deviceKey)
    return ids.length > 0 && ids.every((id: string) => this.isSelected(id))
  }

  @Builder
  private FilterButton(label: string, value: string) {
    Button(label).height(36).padding(0).width(98)
      .layoutWeight(this.compactLayout ? 1 : 0)
      .fontSize(this.compactLayout ? 13 : 12)
      .fontWeight(this.historyFilter === value ? FontWeight.Bold : FontWeight.Medium)
      .fontColor(this.historyFilter === value ? '#FFFFFF' : $r('app.color.text_secondary'))
      .backgroundColor(this.historyFilter === value ? $r('app.color.accent') : Color.Transparent).borderRadius(9)
      .onClick(() => this.onFilterChanged(value))
      .accessibilityDescription(`仅显示${label}的传输记录`)
  }

  private retryIfAvailable(item: TransferListItem): void {
    if (item.direction === TransferDirection.Sending &&
      (item.state === TransferState.Failed || item.state === TransferState.Cancelled)) {
      this.onRetryHistory(item)
    }
  }

  private stateLabel(item: TransferListItem): string {
    if (item.direction === TransferDirection.Sending &&
      (item.state === TransferState.Failed || item.state === TransferState.Cancelled)) {
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

/**
 * 多选期间顶掉悬浮 Dock 的底部操作栏。红色只在这里出现一次：用户已经明确表达了
 * 删除意图并选好了范围，此时强调才是有效的，而不是常驻在页面顶部。
 */
@ComponentV2
export struct HistorySelectionBar {
  @Param selectedCount: number = 0
  @Param allSelected: boolean = false
  @Param onToggleSelectAll: () => void = () => {}
  @Param onDelete: () => void = () => {}

  build() {
    Row({ space: 12 }) {
      Text(this.allSelected ? '取消全选' : '全选')
        .fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.accent'))
        .height(40).padding({ left: 4, right: 4 })
        .onClick(this.onToggleSelectAll)
      Text(this.selectedCount > 0 ? `已选 ${this.selectedCount} 项` : '请选择要删除的记录')
        .fontSize(13).fontColor($r('app.color.text_secondary')).layoutWeight(1).textAlign(TextAlign.Center)
        .maxLines(1)
      Button('删除')
        .height(40).padding({ left: 20, right: 20 }).fontSize(14).fontWeight(FontWeight.Medium)
        .fontColor(this.selectedCount > 0 ? '#FFFFFF' : $r('app.color.text_secondary'))
        .backgroundColor(this.selectedCount > 0 ? $r('app.color.danger') : $r('app.color.control_track'))
        .borderRadius(20).enabled(this.selectedCount > 0).onClick(this.onDelete)
        .accessibilityText(`删除选中的 ${this.selectedCount} 条记录`)
    }
    .width('100%').height(64).padding({ left: 18, right: 18 })
    .backgroundColor($r('app.color.surface_primary'))
    .border({ width: { top: 1 }, color: $r('app.color.border_subtle') })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}
