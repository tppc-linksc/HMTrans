import AppKit
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
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            _ = AppWindowController.showExistingMainWindow()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        DispatchQueue.main.async {
            _ = AppWindowController.showExistingMainWindow()
        }
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
            PrivacyGateView(model: model)
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
