import AppKit
import Combine
import Foundation
import HMTransCore
import SwiftUI

extension Notification.Name {
    static let hmTransOpenFiles = Notification.Name("HMTransOpenFiles")
}

@MainActor
enum AppWindowController {
    static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("HMTransMainWindow")
    private static let closeDelegate = MainWindowCloseDelegate()

    static func configureMainWindow(_ window: NSWindow?) {
        guard let window else { return }
        window.identifier = mainWindowIdentifier
        window.delegate = closeDelegate
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
    }

    @discardableResult
    static func showExistingMainWindow() -> Bool {
        let windows = NSApp.windows.filter { $0.identifier == mainWindowIdentifier }
        guard let window = windows.first else { return false }
        for duplicate in windows.dropFirst() {
            duplicate.close()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}

@MainActor
private final class MainWindowCloseDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private let instanceGuard = MacSingleInstanceGuard()
    @Published private(set) var ownsInstanceLock = false
    private var launchObserver: NSObjectProtocol?

    func applicationWillFinishLaunching(_ notification: Notification) {
        if let existing = RunningHMTransCopies.otherCopy() {
            refuseSecondInstance(existing: existing)
            return
        }
        guard instanceGuard.acquire() else {
            refuseSecondInstance(existing: RunningHMTransCopies.otherCopy())
            return
        }
        ownsInstanceLock = true
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  application.bundleIdentifier == Bundle.main.bundleIdentifier,
                  application.processIdentifier != ProcessInfo.processInfo.processIdentifier
            else { return }
            // 旧版本不认识进程锁时，由已经运行的新版本请求后来副本退出。
            application.terminate()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ownsInstanceLock else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            _ = AppWindowController.showExistingMainWindow()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard ownsInstanceLock else { return }
        DispatchQueue.main.async {
            _ = AppWindowController.showExistingMainWindow()
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        guard ownsInstanceLock else {
            sender.reply(toOpenOrPrint: .failure)
            return
        }
        _ = AppWindowController.showExistingMainWindow()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .hmTransOpenFiles, object: filenames)
        }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard ownsInstanceLock else { return false }
        if AppWindowController.showExistingMainWindow() {
            return false
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(launchObserver)
        }
    }

    private func refuseSecondInstance(existing: NSRunningApplication?) {
        RunningHMTransCopies.activate(existing)
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "HM互传已在运行"
            alert.informativeText = "检测到另一个位置的 HMTrans.app。为避免设备重复发现和端口冲突，本副本不会启动。请先退出已有副本，再打开需要使用的版本。"
            alert.addButton(withTitle: "知道了")
            alert.runModal()
            NSApp.terminate(nil)
        }
    }
}

enum AppIconLoader {
    static func deviceIconImage(platform: String) -> NSImage? {
        let resource = platform == "HarmonyOS" ? "DeviceMatePad" : "DeviceMacBook"
        return Bundle.module.url(forResource: resource, withExtension: "png").flatMap {
            NSImage(contentsOf: $0)
        }
    }
}

@main
struct HMTransMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = TransferViewModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            Group {
                if appDelegate.ownsInstanceLock {
                    PrivacyGateView(model: model)
                } else {
                    Color.clear
                }
            }
            .frame(minWidth: 1040, minHeight: 720)
            .background(MainWindowReader())
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 780)
        .windowResizability(.contentSize)

        Settings {
            SettingsView(model: model)
        }

    }

}

private struct MainWindowReader: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        resolve(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        resolve(nsView)
    }

    private func resolve(_ view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            guard window.identifier != AppWindowController.mainWindowIdentifier else { return }
            AppWindowController.configureMainWindow(window)
            _ = AppWindowController.showExistingMainWindow()
        }
    }
}
