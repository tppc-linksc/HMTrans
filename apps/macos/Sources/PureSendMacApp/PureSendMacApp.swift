import AppKit
import Foundation
import PureSendCore
import SwiftUI

extension Notification.Name {
    static let pureSendOpenFiles = Notification.Name("PureSendOpenFiles")
}

@MainActor
enum AppWindowController {
    static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("PureSendMainWindow")
    private static let closeDelegate = MainWindowCloseDelegate()

    static func configureWindows() {
        for window in NSApp.windows {
            window.identifier = mainWindowIdentifier
            window.delegate = closeDelegate
            window.isReleasedWhenClosed = false
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.backgroundColor = .clear
        }
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
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = AppIconLoader.iconImage() {
            NSApp.applicationIconImage = icon
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AppWindowController.configureWindows()
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        _ = AppWindowController.showExistingMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if AppWindowController.showExistingMainWindow() {
            return false
        }
        return true
    }
}

enum AppIconLoader {
    static func iconImage() -> NSImage? {
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png") {
            return NSImage(contentsOf: url)
        }
        return nil
    }

    static func menuBarIconImage() -> NSImage? {
        nil
    }

    static func deviceIconImage(platform: String) -> NSImage? {
        let resource = platform == "HarmonyOS" ? "DeviceMatePad" : "DeviceMacBook"
        return Bundle.module.url(forResource: resource, withExtension: "png").flatMap {
            NSImage(contentsOf: $0)
        }
    }
}

@main
struct PureSendMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = TransferViewModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(model: model)
                .frame(minWidth: 1040, minHeight: 720)
                .onAppear {
                    AppWindowController.configureWindows()
                    model.bootstrap()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 780)
        .windowResizability(.contentSize)

        Settings {
            SettingsView(model: model)
        }

        MenuBarExtra {
            Text(model.menuSummary)
            Divider()
            Button("显示窗口") {
                revealMainWindow()
            }
            Button("选择文件发送") {
                revealMainWindow()
                DispatchQueue.main.async {
                    model.chooseFile()
                }
            }
            Button(model.receiverRunning ? "接收服务已开启" : "重新开启接收服务") {
                model.startPersistentReceiver()
            }
            Divider()
            Button("退出") {
                NSApp.terminate(nil)
            }
        } label: {
            Image(systemName: "arrow.left.arrow.right.circle.fill")
                .font(.system(size: 19, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 22, height: 22)
        }
    }

    private func revealMainWindow() {
        if AppWindowController.showExistingMainWindow() {
            return
        }
        openWindow(id: "main")
        DispatchQueue.main.async {
            AppWindowController.configureWindows()
            _ = AppWindowController.showExistingMainWindow()
        }
    }
}
