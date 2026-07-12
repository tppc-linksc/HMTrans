import AppKit
import Foundation

/// Keeps user-driven file and receive-directory panels out of the networking controller.
@MainActor
extension TransferViewModel {
    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            selectedFile = panel.urls.first
            sendFiles(panel.urls)
        }
    }

    func chooseReceiveDirectory() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            receiveDirectory = url.path
            UserDefaults.standard.set(url.path, forKey: Self.receiveDirectoryKey)
            status = "接收目录：\(url.path)"
            ensureReceiverAndDiscovery()
        }
    }

    @discardableResult
    func openReceiveDirectory() -> Bool {
        let url = URL(fileURLWithPath: receiveDirectory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            guard NSWorkspace.shared.open(url) else {
                status = "无法打开下载目录：\(receiveDirectory)"
                return false
            }
            status = "已打开下载目录：\(receiveDirectory)"
            return true
        } catch {
            status = "下载目录不可用：\(error.localizedDescription)"
            return false
        }
    }
}
