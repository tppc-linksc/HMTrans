import AppKit
import Darwin
import Foundation

/** 使用进程锁防止不同路径中的 HMTrans.app 同时广播和占用传输端口。 */
final class MacSingleInstanceGuard {
    private var descriptor: Int32 = -1

    func acquire() -> Bool {
        guard descriptor < 0 else { return true }
        do {
            let directory = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("HMTrans/Runtime", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let path = directory.appendingPathComponent("application.lock").path
            let opened = Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard opened >= 0 else { return false }
            guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
                Darwin.close(opened)
                return false
            }
            descriptor = opened
            return true
        } catch {
            NSLog("HMTrans single instance lock failed: %@", error.localizedDescription)
            return false
        }
    }

    deinit {
        if descriptor >= 0 {
            flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
        }
    }
}

@MainActor
enum RunningHMTransCopies {
    static func otherCopy() -> NSRunningApplication? {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }

    static func activate(_ application: NSRunningApplication?) {
        application?.activate(options: [.activateAllWindows])
    }
}
