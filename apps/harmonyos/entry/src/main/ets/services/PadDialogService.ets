import { UIContext } from '@kit.ArkUI'

/**
 * Centralizes Pad confirmation dialogs so page state code only handles the
 * resulting decision. Keeping copy and destructive-button ordering here also
 * prevents subtly different dialogs from appearing for equivalent actions.
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

  /** Returns 0 for back, 1 for cancel-and-keep, and 2 for cancel-and-delete. */
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
