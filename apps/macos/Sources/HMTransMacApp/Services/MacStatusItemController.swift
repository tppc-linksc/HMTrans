import AppKit

/// 状态栏入口只做两件事：显示单色图标，点击回到任务中心。
/// 悬停面板和拖到图标发送都已移除——面板会在鼠标离开的瞬间消失，拖拽过程中
/// 又会被系统的窗口管理手势截走，用户实际无法完成一次投放。
@MainActor
final class MacStatusItemController: NSObject {
    static let shared = MacStatusItemController()

    private var statusItem: NSStatusItem?

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: 34)
        guard let button = item.button else { return }
        button.image = StatusItemIconFactory.menuBarIcon
        button.imagePosition = .imageOnly
        button.toolTip = "HM互传"
        button.target = self
        button.action = #selector(openTaskCenter)
        statusItem = item
    }

    @objc private func openTaskCenter() {
        _ = AppWindowController.showExistingMainWindow()
    }
}

private enum StatusItemIconFactory {
    /// 仅使用大号莫比乌斯 Logo 的透明模板图，让系统适配明暗模式。
    static let menuBarIcon: NSImage? = {
        guard let url = Bundle.module.url(forResource: "MenuBarLogoSolid", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 27, height: 15)
        image.isTemplate = true
        image.accessibilityDescription = "HM互传"
        return image
    }()
}
