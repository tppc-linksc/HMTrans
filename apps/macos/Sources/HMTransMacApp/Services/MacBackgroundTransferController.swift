import Foundation

/// Keeps the Mac awake only while file bytes are actively prepared,
/// transferred, or verified. Idle discovery never owns an activity token.
@MainActor
final class MacBackgroundTransferController {
    private var activity: NSObjectProtocol?

    func setActive(_ active: Bool) {
        if active, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [
                    .userInitiated,
                    .idleSystemSleepDisabled,
                    .suddenTerminationDisabled,
                    .automaticTerminationDisabled,
                ],
                reason: "HM互传正在传输文件"
            )
        } else if !active, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    isolated deinit {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }
}
