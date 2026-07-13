import Foundation
import Network

/// 监听系统默认网络路径，并合并短时间内连续出现的变化事件。
final class MacNetworkChangeMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "HMTrans.NetworkChangeMonitor")
    private let lock = NSLock()
    private var pendingWorkItem: DispatchWorkItem?
    private var started = false

    func start(onChange: @escaping @Sendable () -> Void) {
        lock.withLock {
            guard !started else { return }
            started = true
        }
        monitor.pathUpdateHandler = { [weak self] _ in
            guard let self else { return }
            let workItem = DispatchWorkItem(block: onChange)
            lock.withLock {
                pendingWorkItem?.cancel()
                pendingWorkItem = workItem
            }
            queue.asyncAfter(deadline: .now() + 0.8, execute: workItem)
        }
        monitor.start(queue: queue)
    }

    func stop() {
        lock.withLock {
            pendingWorkItem?.cancel()
            pendingWorkItem = nil
            started = false
        }
        monitor.cancel()
    }
}
