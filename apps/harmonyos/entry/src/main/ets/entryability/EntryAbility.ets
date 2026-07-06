import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { window } from '@kit.ArkUI'

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, 'PureSend', 'EntryAbility onCreate')
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.getMainWindow().then((mainWindow: window.Window) => {
      mainWindow.setWindowLayoutFullScreen(true).catch(() => {})
      mainWindow.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: '#111827',
        navigationBarContentColor: '#111827',
      }).catch(() => {})
    }).catch(() => {})

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(0x0000, 'PureSend', 'Failed to load content: %{public}s', JSON.stringify(err))
      }
    })
  }
}
