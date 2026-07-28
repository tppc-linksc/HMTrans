import Foundation
import Network
import SystemConfiguration

enum MacNetworkChangeEvent: Sendable {
    /// 链路或地址刚发生变化。上层应立即清除旧网络展示，不等待新 SSID 可读。
    case transitioning
    /// 连续变化已经收敛且默认网络路径可用，可以重建发现和接收服务。
    case ready
}

/// 监听默认网络路径、Wi-Fi 链路和 IPv4 配置变化。
///
/// 同一无线网卡从一个 SSID 切到另一个 SSID 时，`NWPathMonitor` 可能始终保持
/// `.satisfied`。这里额外监听 SystemConfiguration 的 en0 链路和地址键；它们由
/// 系统在 DHCP 地址发布时更新，不需要在 Wi-Fi 正切换时同步查询 CoreWLAN。
final class MacNetworkChangeMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "HMTrans.NetworkChangeMonitor")
    private let lock = NSLock()
    private var dynamicStore: SCDynamicStore?
    private var onChange: (@Sendable (MacNetworkChangeEvent) -> Void)?
    private var changeGeneration: UInt = 0
    private var receivedInitialPath = false
    private var pathSatisfied = false
    private var transitioning = false
    private var started = false

    func start(onChange: @escaping @Sendable (MacNetworkChangeEvent) -> Void) {
        let shouldStart = lock.withLock {
            guard !started else { return false }
            started = true
            self.onChange = onChange
            return true
        }
        guard shouldStart else { return }

        startDynamicStoreMonitoring()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let wasInitial: Bool = lock.withLock {
                pathSatisfied = path.status == .satisfied
                if !receivedInitialPath {
                    receivedInitialPath = true
                    return true
                }
                return false
            }
            guard !wasInitial else { return }
            networkConfigurationDidChange(scheduleReady: path.status == .satisfied)
        }
        monitor.start(queue: queue)
    }

    func stop() {
        let store = lock.withLock {
            changeGeneration &+= 1
            onChange = nil
            receivedInitialPath = false
            pathSatisfied = false
            transitioning = false
            started = false
            let value = dynamicStore
            dynamicStore = nil
            return value
        }
        if let store {
            SCDynamicStoreSetDispatchQueue(store, nil)
        }
        monitor.cancel()
    }

    fileprivate func systemConfigurationDidChange() {
        networkConfigurationDidChange(scheduleReady: true)
    }

    private func startDynamicStoreMonitoring() {
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let store = SCDynamicStoreCreate(
            nil,
            "HMTrans.NetworkChangeMonitor" as CFString,
            macNetworkDynamicStoreCallback,
            &context
        ) else {
            return
        }
        let keys = [
            "State:/Network/Interface/en0/IPv4",
            "State:/Network/Interface/en0/Link",
            "State:/Network/Global/IPv4"
        ] as CFArray
        guard SCDynamicStoreSetNotificationKeys(store, keys, nil),
              SCDynamicStoreSetDispatchQueue(store, queue) else {
            return
        }
        lock.withLock {
            guard started else {
                SCDynamicStoreSetDispatchQueue(store, nil)
                return
            }
            dynamicStore = store
        }
    }

    private func networkConfigurationDidChange(scheduleReady: Bool) {
        let transitionCallback: (@Sendable (MacNetworkChangeEvent) -> Void)?
        let generation: UInt?
        (transitionCallback, generation) = lock.withLock {
            guard started, receivedInitialPath else {
                return (nil, nil)
            }
            changeGeneration &+= 1
            let callback = transitioning ? nil : onChange
            transitioning = true
            return (callback, changeGeneration)
        }
        transitionCallback?(.transitioning)
        guard scheduleReady, let generation else { return }

        // Wi-Fi 切换会连续发布 link、IPv4 和默认路由事件。短暂等待只用于合并
        // 这些事件；界面已在上面立即进入切换态，不会继续展示旧网络。
        queue.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            guard let self else { return }
            let callback = lock.withLock {
                guard started,
                      receivedInitialPath,
                      pathSatisfied,
                      changeGeneration == generation else {
                    return nil as (@Sendable (MacNetworkChangeEvent) -> Void)?
                }
                transitioning = false
                return onChange
            }
            callback?(.ready)
        }
    }
}

private func macNetworkDynamicStoreCallback(
    _: SCDynamicStore,
    _: CFArray,
    info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    let monitor = Unmanaged<MacNetworkChangeMonitor>.fromOpaque(info).takeUnretainedValue()
    monitor.systemConfigurationDidChange()
}
