/** 首次隐私确认前只显示纯白页面，不提前加载应用图标或业务内容。 */
@ComponentV2
export struct PadPrivacyBlankPage {
  build() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor('#FFFFFF')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
