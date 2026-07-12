import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { window } from '@kit.ArkUI'

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, 'HMTrans', 'EntryAbility onCreate')
    this.dispatchTransferAction(want)
  }

  onNewWant(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    this.dispatchTransferAction(want)
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.getMainWindow().then((mainWindow: window.Window) => {
      mainWindow.setWindowLayoutFullScreen(true).catch(() => {})
      mainWindow.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
      }).catch(() => {})
    }).catch(() => {})

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(0x0000, 'HMTrans', 'Failed to load content: %{public}s', JSON.stringify(err))
      }
    })
  }

  /** Bridges notification action buttons to the already-running ArkUI page. */
  private dispatchTransferAction(want: Want): void {
    const action = want.parameters?.['hmtransAction']
    if (typeof action === 'string' && action.length > 0) {
      this.context.eventHub.emit('hmtransTransferAction', action)
    }
  }
}
