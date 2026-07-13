import { UIContext } from '@kit.ArkUI'

/**
 * 集中管理 Pad 确认对话框，让页面状态代码只处理最终选择。
 * 文案和破坏性按钮顺序统一放在这里，也可避免同类操作出现细微不同的弹窗。
 */
export class PadDialogService {
  async confirm(
    context: UIContext,
    title: string,
    message: string,
    confirmText: string = '确认',
  ): Promise<boolean> {
    try {
      const result = await context.getPromptAction().showDialog({
        title,
        message,
        buttons: [
          { text: '取消', color: '#64748B' },
          { text: confirmText, color: '#C2413A' },
        ],
      })
      return result.index === 1
    } catch (_err) {
      return false
    }
  }

  async confirmReceive(
    context: UIContext,
    sender: string,
    fileName: string,
    sizeText: string,
  ): Promise<boolean> {
    try {
      const result = await context.getPromptAction().showDialog({
        title: `接收来自 ${sender} 的文件？`,
        message: `${fileName}\n大小：${sizeText}\n首次确认后会信任此设备。`,
        buttons: [
          { text: '拒绝', color: '#64748B' },
          { text: '信任并接收', color: '#2563EB' },
        ],
      })
      return result.index === 1
    } catch (_err) {
      return false
    }
  }

  /** 返回 0 表示返回，1 表示取消并保留，2 表示取消并删除。 */
  async cancellationPolicy(context: UIContext, title: string, message: string): Promise<number> {
    try {
      const result = await context.getPromptAction().showDialog({
        title,
        message,
        buttons: [
          { text: '返回', color: '#64748B' },
          { text: '取消并保留', color: '#2563EB' },
          { text: '取消并删除', color: '#C2413A' },
        ],
      })
      return result.index
    } catch (_err) {
      return 0
    }
  }
}
