import Foundation

/// 仅在准备、传输或校验文件字节期间保持 Mac 唤醒；空闲发现不会持有活动令牌。
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
