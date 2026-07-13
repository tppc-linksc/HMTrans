import { DividerMode, HdsTabs, hdsMaterial } from '@kit.UIDesignKit'

/**
 * HarmonyOS 6.1 原生悬浮标签栏。沉浸光感材质和 EXQUISITE 精致光学等级由系统提供，
 * 不使用手工绘制的模糊背景层。
 */
@ComponentV2
export struct BottomDock {
  @Param activePage: string = 'connection'
  @Param onPageChanged: (page: string) => void = (_page: string) => {}

  build() {
    HdsTabs({ barPosition: BarPosition.End, index: this.pageIndex() }) {
      TabContent() { Column() }.tabBar(this.ConnectionTab)
      TabContent() { Column() }.tabBar(this.HistoryTab)
      TabContent() { Column() }.tabBar(this.SettingsTab)
    }
    // 悬浮栏宽 228vp，宿主必须额外容纳系统默认的左右安全边距；
    // 两者同宽时系统会回退为带分割线的普通底部页签。
    .width(280)
    .height(88)
    .vertical(false)
    .barMode(BarMode.Fixed)
    .barHeight(52)
    .barOverlap(true)
    .divider({ mode: DividerMode.NONE })
    .scrollable(false)
    .barFloatingStyle({
      barWidth: { smallWidth: 228, mediumWidth: 228, largeWidth: 228 },
      barSideMargin: 16,
      barBottomMargin: 24,
      adaptToHandedness: false,
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsMaterial.MaterialLevel.EXQUISITE,
      },
      thermoCtrl: true,
    })
    .onChange((index: number) => {
      const page = this.pageAt(index)
      // HdsTabs 在材质层重新布局时可能重复回调同一页，忽略无效切换，
      // 避免父页面发生一次不必要的响应式刷新。
      if (page !== this.activePage) {
        this.onPageChanged(page)
      }
    })
  }

  @Builder
  private ConnectionTab() {
    this.DockItem('连接', 'connection')
  }

  @Builder
  private HistoryTab() {
    this.DockItem('历史', 'history')
  }

  @Builder
  private SettingsTab() {
    this.DockItem('设置', 'settings')
  }

  @Builder
  private DockItem(label: string, page: string) {
    Column({ space: 1 }) {
      this.DockIcon(page)
      Text(label).fontSize(10)
        .fontWeight(this.activePage === page ? FontWeight.Bold : FontWeight.Regular)
        .fontColor(this.activePage === page ? $r('app.color.accent') : $r('app.color.text_secondary'))
    }
    .width(66).height(44).justifyContent(FlexAlign.Center)
    // 自定义 tabBar 的点击直接驱动业务页面，不等待 HdsTabs 的切换动画结束；
    // 透明背景确保文字、图标及其四周留白都是连续的点击热区。
    .backgroundColor(Color.Transparent)
    .onClick(() => {
      if (page !== this.activePage) {
        this.onPageChanged(page)
      }
    })
    .accessibilityText(label)
    .accessibilityDescription(`切换到${label}页面`)
  }

  @Builder
  private DockIcon(page: string) {
    if (page === 'connection') {
      Image(this.activePage === page ? $r('app.media.icon_nav_connection_active') : $r('app.media.icon_nav_connection'))
        .width(21).height(21).accessibilityText('连接')
    } else if (page === 'history') {
      Image(this.activePage === page ? $r('app.media.icon_nav_history_active') : $r('app.media.icon_nav_history'))
        .width(21).height(21).accessibilityText('历史')
    } else {
      Image(this.activePage === page ? $r('app.media.icon_nav_settings_active') : $r('app.media.icon_nav_settings'))
        .width(21).height(21).accessibilityText('设置')
    }
  }

  private pageIndex(): number {
    if (this.activePage === 'history') return 1
    if (this.activePage === 'settings') return 2
    return 0
  }

  private pageAt(index: number): string {
    if (index === 1) return 'history'
    if (index === 2) return 'settings'
    return 'connection'
  }
}
