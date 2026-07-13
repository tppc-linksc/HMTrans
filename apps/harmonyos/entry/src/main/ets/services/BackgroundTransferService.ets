import { common, wantAgent } from '@kit.AbilityKit'
import { backgroundTaskManager } from '@kit.BackgroundTasksKit'
import { notificationManager } from '@kit.NotificationKit'
import { errorText } from '../common/ErrorText'

const TRANSFER_NOTIFICATION_ID: number = 51888

/**
 * Owns the HarmonyOS continuous data-transfer task.
 * A reference count prevents concurrent file sessions from stopping each
 * other's system background task. No task is held while the app is idle.
 */
export class BackgroundTransferService {
  private activeSessionCount: number = 0
  private running: boolean = false
  private enabled: boolean = true

  async setEnabled(enabled: boolean, context: common.UIAbilityContext): Promise<void> {
    this.enabled = enabled
    if (!enabled) {
      await this.stop(context)
    } else if (this.activeSessionCount > 0) {
      await this.startIfNeeded(context)
    }
  }

  async begin(context: common.UIAbilityContext): Promise<void> {
    this.activeSessionCount += 1
    await this.startIfNeeded(context)
  }

  /** Starts protection when the setting is enabled and at least one session is active. */
  private async startIfNeeded(context: common.UIAbilityContext): Promise<void> {
    if (!this.enabled || this.running || this.activeSessionCount === 0) {
      return
    }
    try {
      const agent = await wantAgent.getWantAgent({
        wants: [{
          bundleName: context.abilityInfo.bundleName,
          abilityName: context.abilityInfo.name,
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 51888,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
      })
      await backgroundTaskManager.startBackgroundRunning(
        context,
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER,
        agent
      )
      await this.publishControls(context).catch(() => {})
      this.running = true
    } catch (err) {
      this.running = false
      throw new Error(`后台传输保护启动失败：${errorText(err)}`)
    }
  }

  async end(context: common.UIAbilityContext): Promise<void> {
    this.activeSessionCount = Math.max(0, this.activeSessionCount - 1)
    if (this.activeSessionCount === 0) {
      await this.stop(context)
    }
  }

  async stopAll(context: common.UIAbilityContext): Promise<void> {
    this.activeSessionCount = 0
    await this.stop(context)
  }

  private async stop(context: common.UIAbilityContext): Promise<void> {
    if (!this.running) {
      return
    }
    await backgroundTaskManager.stopBackgroundRunning(context).catch(() => {})
    await notificationManager.cancel(TRANSFER_NOTIFICATION_ID).catch(() => {})
    this.running = false
  }

  /** Adds explicit task controls in addition to the system data-transfer notice. */
  private async publishControls(context: common.UIAbilityContext): Promise<void> {
    try {
      const pauseAgent = await this.actionAgent(context, 'pause_all', 51881)
      const cancelAgent = await this.actionAgent(context, 'cancel_all', 51882)
      await notificationManager.publish({
        id: TRANSFER_NOTIFICATION_ID,
        notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
        isOngoing: true,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: 'HM互传正在传输',
            text: '任务可在后台继续，点击按钮可暂停/继续或取消全部任务',
          },
        },
        actionButtons: [
          { title: '暂停/继续', wantAgent: pauseAgent },
          { title: '取消全部', wantAgent: cancelAgent },
        ],
      })
    } catch (err) {
      throw new Error(`后台通知发布失败：${errorText(err)}`)
    }
  }

  private async actionAgent(context: common.UIAbilityContext, action: string,
    requestCode: number): Promise<object> {
    try {
      return await wantAgent.getWantAgent({
        wants: [{
          bundleName: context.abilityInfo.bundleName,
          abilityName: context.abilityInfo.name,
          parameters: { hmtransAction: action },
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
      })
    } catch (err) {
      throw new Error(`通知操作创建失败：${errorText(err)}`)
    }
  }
}
