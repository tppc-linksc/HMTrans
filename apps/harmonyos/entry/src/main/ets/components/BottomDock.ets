import { HdsTabs, hdsMaterial } from '@kit.UIDesignKit'

/**
 * HarmonyOS 6.1 native floating tabs. The system owns the immersive-light
 * material and EXQUISITE optical level instead of a hand-painted blur layer.
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
    .width(228)
    .height(76)
    .barMode(BarMode.Fixed)
    .barHeight(52)
    .scrollable(false)
    .barFloatingStyle({
      barWidth: { smallWidth: 228, mediumWidth: 228, largeWidth: 228 },
      barBottomMargin: 12,
      adaptToHandedness: false,
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsMaterial.MaterialLevel.EXQUISITE,
      },
      thermoCtrl: true,
    })
    .onChange((index: number) => this.onPageChanged(this.pageAt(index)))
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
        .fontColor(this.activePage === page ? '#247BCD' : $r('app.color.text_secondary'))
    }
    .width(66).height(44).justifyContent(FlexAlign.Center)
  }

  @Builder
  private DockIcon(page: string) {
    if (page === 'connection') {
      Image(this.activePage === page ? $r('app.media.icon_nav_connection_active') : $r('app.media.icon_nav_connection'))
        .width(21).height(21)
    } else if (page === 'history') {
      Image(this.activePage === page ? $r('app.media.icon_nav_history_active') : $r('app.media.icon_nav_history'))
        .width(21).height(21)
    } else {
      Image(this.activePage === page ? $r('app.media.icon_nav_settings_active') : $r('app.media.icon_nav_settings'))
        .width(21).height(21)
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
