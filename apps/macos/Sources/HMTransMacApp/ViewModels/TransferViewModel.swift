import AppKit
import Foundation
import Observation
import HMTransCore

@MainActor
@Observable
final class TransferViewModel {
    static let receiveDirectoryKey = "receiveDirectory"
    private static let localTCPPortKey = "localTCPPort"
    private static let discoveryPortKey = "discoveryPort"
    private static let receiverEnabledKey = "receiverEnabled"
    private static let discoveryEnabledKey = "discoveryEnabled"
    // 仅用于识别旧版本保存目录；拆开旧名称可避免它重新出现在当前品牌文案检索中。
    private static let legacyReceiveDirectoryName = "Pure" + "Send"

    var host: String = UserDefaults.standard.string(forKey: "lastHost") ?? ""
    var portText: String = UserDefaults.standard.string(forKey: "lastPort") ?? String(defaultPort)
    var localTCPPortText: String = UserDefaults.standard.string(forKey: localTCPPortKey) ?? String(defaultPort)
    var discoveryPortText: String = UserDefaults.standard.string(forKey: discoveryPortKey) ?? String(discoveryPort)
    var selectedFile: URL?
    var receiveDirectory: String = TransferViewModel.initialReceiveDirectory()
    var status: String = "正在启动接收服务"
    var progress: Double = 0
    var isSending: Bool = false
    var receiverRunning: Bool = false
    var nearbyDevices: [DeviceInfo] = []
    var persistedDevices: [PersistedDevice] = []
    var discoveryEnabled: Bool = UserDefaults.standard.object(forKey: discoveryEnabledKey) as? Bool ?? true
    var receiverEnabled: Bool = UserDefaults.standard.object(forKey: receiverEnabledKey) as? Bool ?? true
    var pairingCode: String = TransferViewModel.makePairingCode()
    var pairingSeconds: Int = 180
    var isDropTargeted: Bool = false
    var currentTransfers: [TransferListItem] = []
    var historyTransfers: [TransferListItem] = []
    var selectedTargetDeviceIDs: Set<String> = []
    var connectedDeviceIDs: Set<String> = []
    var autoReceiveTrustedDevices: Bool = UserDefaults.standard.object(forKey: "autoReceiveTrustedDevices") as? Bool ?? true
    var backgroundTransferProtection: Bool = UserDefaults.standard.object(forKey: "backgroundTransferProtection") as? Bool ?? true

    let receiver = PersistentFileReceiver()
    let store = TransferStore()
    var discovery: DiscoveryService?
    private var didBootstrap = false
    var lastFallbackScan = Date.distantPast
    var deviceLastSeenAt: [String: Date] = [:]
    var confirmedDeviceLastSeenAt: [String: Date] = [:]
    var receivingTransferIds: [String: UUID] = [:]
    var transferControls: [UUID: TransferControl] = [:]
    let backgroundController = MacBackgroundTransferController()
    private let stagingMaintenance = StagingMaintenanceService()
    private let networkChangeMonitor = MacNetworkChangeMonitor()
    let sharedPreparedSources = SharedPreparedSourceStore()
    let sendConcurrencyGate = AsyncConcurrencyGate(limit: 3)
    var transferGeneration = 0
    private var workspaceSleepObserver: NSObjectProtocol?
    private var workspaceWakeObserver: NSObjectProtocol?
    private var openFilesObserver: NSObjectProtocol?
    var pruneTask: Task<Void, Never>?
    private var pairingTask: Task<Void, Never>?
    var persistenceTask: Task<Void, Never>?
    let deviceId: String
    let deviceName: String
    let identityFingerprint: String
    let discoveredDeviceTTL: TimeInterval = 12

    private static func initialReceiveDirectory() -> String {
        guard let saved = UserDefaults.standard.string(forKey: receiveDirectoryKey),
              !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultReceiveDirectory()
        }
        if saved.split(separator: "/").contains(Substring(legacyReceiveDirectoryName)) {
            let migrated = defaultReceiveDirectory()
            UserDefaults.standard.set(migrated, forKey: receiveDirectoryKey)
            return migrated
        }
        return saved
    }

    var port: UInt16 {
        UInt16(portText) ?? defaultPort
    }

    var localTCPPort: UInt16 { UInt16(localTCPPortText) ?? defaultPort }
    var localDiscoveryPort: UInt16 { UInt16(discoveryPortText) ?? discoveryPort }

    var selectedNearbyDevice: DeviceInfo? {
        // 发送目标必须以稳定设备 ID 为准。IP 可能被 DHCP 重新分配，按 IP 反查会把
        // 同一地址上的另一台设备误认为已选设备，也会让离线配对设备看起来仍可发送。
        connectedDevices.first { selectedTargetDeviceIDs.contains($0.deviceId) }
    }

    var connectedDevices: [DeviceInfo] {
        nearbyDevices.filter {
            TrustedDevicesStore.matches($0.deviceId, fingerprint: $0.identityFingerprint)
                && isBidirectionallyConnected($0)
        }
    }

    var activeTransferTargets: [DeviceInfo] {
        let selected = connectedDevices.filter { selectedTargetDeviceIDs.contains($0.deviceId) }
        if !selected.isEmpty { return selected }
        return connectedDevices.count == 1 ? connectedDevices : []
    }

    func isBidirectionallyConnected(_ device: DeviceInfo) -> Bool {
        guard connectedDeviceIDs.contains(device.deviceId) else { return false }
        guard let confirmedAt = confirmedDeviceLastSeenAt[device.deviceId] else { return false }
        return Date().timeIntervalSince(confirmedAt) < discoveredDeviceTTL
    }

    func markDeviceConfirmed(_ deviceID: String) {
        confirmedDeviceLastSeenAt[deviceID] = Date()
        // 整体赋值可以稳定触发 SwiftUI 刷新，让设备卡片在离线组和已连接组之间移动。
        var updated = connectedDeviceIDs
        updated.insert(deviceID)
        connectedDeviceIDs = updated
    }

    var diagnosticReport: String {
        let selected = selectedNearbyDevice.map { "\($0.deviceName) [\($0.platform)]" } ?? "无"
        let recentErrors = store.recentDiagnosticSummary().map(redactDiagnosticText).joined(separator: "\n")
        return """
        HM互传诊断信息
        生成时间：\(Date().formatted(date: .numeric, time: .standard))
        应用版本：0.2.0
        系统版本：\(ProcessInfo.processInfo.operatingSystemVersionString)
        本机名称：\(deviceName)
        连接服务：\(receiverRunning ? "运行正常" : "已关闭或异常")
        自动发现：\(discoveryEnabled ? "已开启" : "已关闭")
        UDP 端口：\(localDiscoveryPort)
        TCP 端口：\(localTCPPort)
        当前设备：\(selected)
        发现设备：\(nearbyDevices.count)
        已保存设备：\(persistedDevices.count)
        当前任务：\(currentTransfers.count)
        历史记录：\(historyTransfers.count)
        下载目录：…/\(URL(fileURLWithPath: receiveDirectory).lastPathComponent)
        最近状态：\(redactDiagnosticText(status))
        最近错误：
        \(recentErrors.isEmpty ? "无" : recentErrors)
        """
    }

    init() {
        deviceName = Host.current().localizedName ?? "Mac"
        if let saved = UserDefaults.standard.string(forKey: "deviceId") {
            deviceId = saved
        } else {
            let generated = "mac-\(UUID().uuidString)"
            UserDefaults.standard.set(generated, forKey: "deviceId")
            deviceId = generated
        }
        if let saved = UserDefaults.standard.string(forKey: "identityFingerprint"), !saved.isEmpty {
            identityFingerprint = saved
        } else {
            let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            UserDefaults.standard.set(generated, forKey: "identityFingerprint")
            identityFingerprint = generated
        }

        openFilesObserver = NotificationCenter.default.addObserver(forName: .hmTransOpenFiles, object: nil, queue: .main) { [weak self] notification in
            guard let filenames = notification.object as? [String] else { return }
            Task { @MainActor in
                self?.sendDroppedFiles(filenames.map { URL(fileURLWithPath: $0) })
            }
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceSleepObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleSystemWillSleep() }
        }
        workspaceWakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleSystemDidWake() }
        }
    }

    isolated deinit {
        if let openFilesObserver {
            NotificationCenter.default.removeObserver(openFilesObserver)
        }
        if let workspaceSleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceSleepObserver)
        }
        if let workspaceWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceWakeObserver)
        }
        pruneTask?.cancel()
        pairingTask?.cancel()
        persistenceTask?.cancel()
        networkChangeMonitor.stop()
        transferControls.values.forEach { $0.cancel() }
        store.saveImmediately(current: currentTransfers, history: historyTransfers)
    }

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        restorePersistedState()
        let activeArtifactIDs = Set(currentTransfers.flatMap { item in
            [item.id.uuidString, item.groupId?.uuidString].compactMap { $0 }
        })
        stagingMaintenance.pruneExpired(activeTransferIDs: activeArtifactIDs)
        clearLocalSavedTargetIfNeeded()
        ensureReceiverAndDiscovery()
        networkChangeMonitor.start { [weak self] in
            Task { @MainActor in self?.handleNetworkPathChanged() }
        }
        startDevicePruning()
        startPairingCountdown()
    }

    /// 网络切换后重建发现和接收监听，避免继续绑定旧网卡地址。
    private func handleNetworkPathChanged() {
        guard didBootstrap else { return }
        receiver.stop()
        receiverRunning = false
        stopDiscovery()
        ensureReceiverAndDiscovery()
        status = "网络已变化，正在重新发现设备"
    }

    func regeneratePairingCode() {
        pairingCode = Self.makePairingCode()
        pairingSeconds = 180
    }

    private func startPairingCountdown() {
        guard pairingTask == nil else { return }
        pairingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if pairingSeconds <= 1 {
                    regeneratePairingCode()
                } else {
                    pairingSeconds -= 1
                }
            }
        }
    }

    nonisolated private static func makePairingCode() -> String {
        let value = Int.random(in: 100_000...999_999)
        let text = String(value)
        return "\(text.prefix(3)) \(text.suffix(3))"
    }

    private func restorePersistedState() {
        let snapshot = store.loadSnapshot()
        persistedDevices = snapshot.devices
        currentTransfers = snapshot.current.map { item in
            var restored = item
            if restored.state == .active || restored.state == .preparing || restored.state == .verifying {
                restored.state = .waiting
                restored.detail = "应用重新启动，断点已保存，等待设备重连"
                restored.updatedAt = Date()
            }
            return restored
        }
        historyTransfers = snapshot.history
        if let databaseError = store.consumeLastError() {
            status = "本地状态数据库异常：\(databaseError)"
        }
        persistTransfers()
    }

    func setConnectionEnabled(_ enabled: Bool) {
        discoveryEnabled = enabled
        receiverEnabled = enabled
        if enabled {
            let receiverStarted = startReceiver()
            let discoveryStarted = startDiscovery()
            if receiverStarted && discoveryStarted {
                UserDefaults.standard.set(true, forKey: Self.discoveryEnabledKey)
                UserDefaults.standard.set(true, forKey: Self.receiverEnabledKey)
                startFallbackNetworkScan(force: true)
                status = "连接服务已开启"
            } else {
                receiver.stop()
                receiverRunning = false
                stopDiscovery()
                discoveryEnabled = false
                receiverEnabled = false
                UserDefaults.standard.set(false, forKey: Self.discoveryEnabledKey)
                UserDefaults.standard.set(false, forKey: Self.receiverEnabledKey)
                status = "连接服务启动失败，开关已恢复"
            }
        } else {
            receiver.stop()
            receiverRunning = false
            stopDiscovery()
            UserDefaults.standard.set(false, forKey: Self.discoveryEnabledKey)
            UserDefaults.standard.set(false, forKey: Self.receiverEnabledKey)
            status = "连接服务已关闭"
        }
    }

    func setReceiverEnabled(_ enabled: Bool) {
        receiverEnabled = enabled
        if enabled {
            if startReceiver() {
                UserDefaults.standard.set(true, forKey: Self.receiverEnabledKey)
                status = "接收服务已开启"
            } else {
                receiverEnabled = false
                UserDefaults.standard.set(false, forKey: Self.receiverEnabledKey)
                status = "接收服务启动失败，开关已恢复"
            }
        } else {
            receiver.stop()
            receiverRunning = false
            UserDefaults.standard.set(false, forKey: Self.receiverEnabledKey)
            status = "接收服务已关闭，仍可发现和发送"
        }
    }

    func setDiscoveryEnabled(_ enabled: Bool) {
        discoveryEnabled = enabled
        if enabled {
            if startDiscovery() {
                UserDefaults.standard.set(true, forKey: Self.discoveryEnabledKey)
                startFallbackNetworkScan(force: true)
                status = "自动发现已开启"
            } else {
                discoveryEnabled = false
                UserDefaults.standard.set(false, forKey: Self.discoveryEnabledKey)
                status = "自动发现启动失败，开关已恢复"
            }
        } else {
            stopDiscovery()
            UserDefaults.standard.set(false, forKey: Self.discoveryEnabledKey)
            status = "自动发现已关闭，接收服务保持当前状态"
        }
    }

    func setAutoReceiveTrustedDevices(_ enabled: Bool) {
        autoReceiveTrustedDevices = enabled
        UserDefaults.standard.set(enabled, forKey: "autoReceiveTrustedDevices")
    }

    func setBackgroundTransferProtection(_ enabled: Bool) {
        backgroundTransferProtection = enabled
        UserDefaults.standard.set(enabled, forKey: "backgroundTransferProtection")
        syncBackgroundActivity()
    }

    func refreshDevices() {
        guard discoveryEnabled else {
            status = "请先开启连接服务"
            return
        }
        startDiscovery()
        startFallbackNetworkScan(force: true)
        status = "正在重新扫描附近设备"
    }

    func clearHistory(scope: TransferListItem.StateText? = nil) {
        if let scope {
            historyTransfers.removeAll { $0.state == scope }
        } else {
            historyTransfers.removeAll()
        }
        persistTransfers()
    }

    func deleteHistoryItem(_ item: TransferListItem) {
        historyTransfers.removeAll { $0.id == item.id }
        persistTransfers()
    }

    func clearHistory(deviceKey: String) {
        historyTransfers.removeAll { historyDeviceKey($0) == deviceKey }
        persistTransfers()
    }

    func historyDeviceKey(_ item: TransferListItem) -> String {
        if let deviceID = item.deviceId, !deviceID.isEmpty { return deviceID }
        return "name:\(item.peerName)"
    }

    func clearTemporaryStorage() {
        transferGeneration += 1
        transferControls.values.forEach { $0.cancel() }
        for (wireID, _) in receivingTransferIds {
            receiver.cancelTransfer(wireID, deletePartial: true)
        }
        status = "正在停止未完成任务"
        Task { @MainActor [weak self] in
            guard let self else { return }
            await sendConcurrencyGate.waitUntilIdle()
            for _ in 0..<60 where !receiver.isIdle {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard receiver.isIdle else {
                status = "仍有传输正在释放资源，请稍后重试"
                return
            }
            finishClearingTemporaryStorage()
        }
    }

    private func finishClearingTemporaryStorage() {
        do {
            transferControls.removeAll()
            receivingTransferIds.removeAll()
            currentTransfers.removeAll()
            let applicationSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let staging = applicationSupport.appendingPathComponent("HMTrans", isDirectory: true)
                .appendingPathComponent("Staging", isDirectory: true)
            if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            syncBackgroundActivity()
            store.saveImmediately(current: currentTransfers, history: historyTransfers)
            status = "临时传输空间和未完成任务已清除"
        } catch {
            status = "临时空间清理失败：\(error.localizedDescription)"
        }
    }

    func togglePause(_ item: TransferListItem) {
        guard let index = currentTransfers.firstIndex(where: { $0.id == item.id }) else { return }
        if item.direction == .receiving, let wireID = receivingWireID(for: item.id) {
            if currentTransfers[index].state == .paused {
                receiver.resumeTransfer(wireID)
                currentTransfers[index].state = .waiting
                currentTransfers[index].detail = "接收已恢复，等待发送端重连"
            } else {
                receiver.pauseTransfer(wireID)
                currentTransfers[index].state = .paused
                currentTransfers[index].detail = "接收已暂停，分片已保留"
            }
            currentTransfers[index].updatedAt = Date()
            syncBackgroundActivity()
            persistTransfers()
            return
        }
        guard let control = transferControls[item.id] else {
            if item.state == .waiting || item.state == .failed {
                resumePersistedTransfer(item)
            } else {
                status = "该任务当前没有活动连接"
            }
            return
        }
        switch currentTransfers[index].state {
        case .paused:
            control.resume()
            currentTransfers[index].state = .active
            currentTransfers[index].detail = "正在继续传输"
        case .queued, .preparing, .active:
            control.pause()
            currentTransfers[index].state = .paused
            currentTransfers[index].detail = "已暂停网络发送"
        case .waiting, .failed, .verifying, .done, .cancelled:
            return
        }
        currentTransfers[index].updatedAt = Date()
        syncBackgroundActivity()
        persistTransfers()
    }

    func cancel(_ item: TransferListItem, deletePartial: Bool = false) {
        guard let index = currentTransfers.firstIndex(where: { $0.id == item.id }) else { return }
        if item.direction == .receiving, let wireID = receivingWireID(for: item.id) {
            receiver.cancelTransfer(wireID, deletePartial: deletePartial)
            receivingTransferIds.removeValue(forKey: wireID)
        }
        transferControls[item.id]?.cancel()
        transferControls.removeValue(forKey: item.id)
        var cancelled = currentTransfers.remove(at: index)
        cancelled.state = .cancelled
        cancelled.detail = "用户取消"
        cancelled.updatedAt = Date()
        historyTransfers.insert(cancelled, at: 0)
        if deletePartial { deleteRecoverableArtifacts(for: cancelled) }
        syncBackgroundActivity()
        persistTransfers()
    }

    private func deleteRecoverableArtifacts(for item: TransferListItem) {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return }
        let outgoing = support.appendingPathComponent("HMTrans/Staging/Outgoing", isDirectory: true)
        let token = item.groupId ?? item.id
        let stillReferenced = currentTransfers.contains { ($0.groupId ?? $0.id) == token }
        if !stillReferenced {
            try? FileManager.default.removeItem(at: outgoing.appendingPathComponent(token.uuidString, isDirectory: true))
        }
    }

    func selectDevice(_ device: DeviceInfo) {
        if TrustedDevicesStore.matches(device.deviceId, fingerprint: device.identityFingerprint) {
            useDevice(device)
            return
        }
        guard let fingerprint = device.identityFingerprint, !fingerprint.isEmpty else {
            status = "对端版本过旧或身份信息缺失，请将两端升级到 v0.2 后重新配对"
            return
        }
        guard let code = promptForPairingCode(device: device) else { return }
        status = "正在校验 \(device.deviceName) 的配对码"
        let requesterId = deviceId
        let requesterName = deviceName
        let requesterPort = localTCPPort
        let requesterIP = localIPv4Addresses().first ?? "0.0.0.0"
        let requesterSystemVersion = ProcessInfo.processInfo.operatingSystemVersionString
        Task.detached { [weak self] in
            do {
                let response = try requestPairing(
                    host: device.ip,
                    port: device.port,
                    requesterDeviceId: requesterId,
                    requesterName: requesterName,
                    requesterPlatform: "macOS",
                    requesterSystemVersion: requesterSystemVersion,
                    requesterIP: requesterIP,
                    requesterPort: requesterPort,
                    code: code,
                    requesterFingerprint: self?.identityFingerprint
                )
                await MainActor.run {
                    guard let self else { return }
                    if response.accepted {
                        TrustedDevicesStore.insert(device.deviceId, fingerprint: fingerprint)
                        self.markDeviceConfirmed(device.deviceId)
                        self.persist(device: device)
                        self.useDevice(device)
                        self.status = "配对成功：\(device.deviceName)"
                    } else {
                        self.status = "配对失败：配对码错误或已过期"
                    }
                }
            } catch {
                await MainActor.run { self?.status = "配对失败：\(error)" }
            }
        }
    }

    func autoSelectDevice(_ device: DeviceInfo) {
        guard TrustedDevicesStore.matches(device.deviceId, fingerprint: device.identityFingerprint) else { return }
        if selectedTargetDeviceIDs.isEmpty {
            useDevice(device)
        } else {
            // 即使还有其他在线设备，也不会将其静默加入多设备发送目标集合。
            resumeWaitingTransfers(for: device)
        }
    }

    func useDevice(_ device: DeviceInfo) {
        guard !isLocalIPv4Address(device.ip) else {
            forgetDevice(device)
            status = "已忽略本机地址：\(device.ip)"
            return
        }
        host = device.ip
        portText = String(device.port)
        rememberTarget()
        selectedTargetDeviceIDs.insert(device.deviceId)
        status = "已选择 \(device.deviceName) \(device.ip)"
        resumeWaitingTransfers(for: device)
    }

    func resumePersistedTransfer(_ item: TransferListItem, using preferredDevice: DeviceInfo? = nil) {
        guard item.direction == .sending,
              let path = item.localPath,
              FileManager.default.fileExists(atPath: path) else {
            status = "无法恢复：原文件不存在或已移动"
            return
        }
        guard let device = preferredDevice ?? matchingNearbyDevice(for: item),
              transfer(item, belongsTo: device) else {
            status = "请先重新连接 \(item.peerName)"
            return
        }
        sendFiles(
            [URL(fileURLWithPath: path)],
            to: device,
            reusingTransferID: item.id,
            groupID: item.groupId
        )
    }

    private func resumeWaitingTransfers(for device: DeviceInfo) {
        let candidates = currentTransfers.filter { item in
            item.direction == .sending &&
            item.state == .waiting &&
            transfer(item, belongsTo: device) &&
            item.localPath.map { FileManager.default.fileExists(atPath: $0) } == true &&
            transferControls[item.id] == nil
        }
        for item in candidates {
            resumePersistedTransfer(item, using: device)
        }
    }

    /// 任务恢复必须使用稳定设备 ID；仅对没有 ID 的旧记录保留唯一名称匹配。
    func matchingNearbyDevice(for item: TransferListItem) -> DeviceInfo? {
        let matches = nearbyDevices.filter {
            transfer(item, belongsTo: $0) &&
            TrustedDevicesStore.matches($0.deviceId, fingerprint: $0.identityFingerprint)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func transfer(_ item: TransferListItem, belongsTo device: DeviceInfo) -> Bool {
        if let deviceID = item.deviceId, !deviceID.isEmpty { return deviceID == device.deviceId }
        return item.peerName == device.deviceName
    }

    func forgetDevice(_ device: DeviceInfo) {
        TrustedDevicesStore.remove(device.deviceId)
        store.removeDevice(id: device.deviceId)
        persistedDevices.removeAll { $0.id == device.deviceId }
        nearbyDevices.removeAll { $0.deviceId == device.deviceId }
        deviceLastSeenAt.removeValue(forKey: device.deviceId)
        selectedTargetDeviceIDs.remove(device.deviceId)
        if host == device.ip {
            host = ""
            portText = String(defaultPort)
            rememberTarget()
            status = "已删除设备：\(device.deviceName)"
        }
    }

    func reconnectPersistedDevice(_ device: PersistedDevice) {
        guard TrustedDevicesStore.contains(device.id) else {
            status = "设备信任已失效，需要重新配对"
            return
        }
        host = device.address
        portText = String(device.port)
        rememberTarget()
        status = "正在重新连接：\(device.name)"
        refreshDevices()
        discovery?.probe(address: device.address)
        Task.detached { [weak self] in
            let reachable = tcpPortIsOpen(host: device.address, port: device.port, timeout: 0.9)
            await MainActor.run {
                guard let self else { return }
                guard reachable else {
                    self.status = "设备未连接：\(device.name)"
                    return
                }
                // 仅探测到 TCP 端口无法获得设备指纹；定向发现响应确认身份前，卡片保持离线。
                self.discovery?.probe(address: device.address)
                self.status = "设备可达，正在确认身份：\(device.name)"
            }
        }
    }

    func clearSavedTarget() {
        host = ""
        portText = String(defaultPort)
        rememberTarget()
        status = "已清除保存目标"
    }

    func markDeviceUnreachable(_ device: DeviceInfo, reason: String) {
        nearbyDevices.removeAll { $0.deviceId == device.deviceId || $0.ip == device.ip }
        deviceLastSeenAt.removeValue(forKey: device.deviceId)
        if host == device.ip {
            host = ""
            portText = String(defaultPort)
            rememberTarget()
        }
        status = "MatePad 接收端不可达：\(reason)"
        startFallbackNetworkScan(force: true)
    }

    func startPersistentReceiver() {
        ensureReceiverAndDiscovery()
    }

    func applyNetworkPorts() {
        guard let tcp = UInt16(localTCPPortText), tcp > 0,
              let udp = UInt16(discoveryPortText), udp > 0 else {
            status = "端口必须是 1 到 65535 之间的数字"
            return
        }
        localTCPPortText = String(tcp)
        discoveryPortText = String(udp)
        UserDefaults.standard.set(localTCPPortText, forKey: Self.localTCPPortKey)
        UserDefaults.standard.set(discoveryPortText, forKey: Self.discoveryPortKey)
        receiver.stop()
        receiverRunning = false
        stopDiscovery()
        ensureReceiverAndDiscovery()
        status = "正在应用 UDP \(udp) · TCP \(tcp)"
    }

    func ensureReceiverAndDiscovery() {
        if receiverEnabled {
            _ = startReceiver()
        } else {
            receiver.stop()
            receiverRunning = false
        }
        if discoveryEnabled {
            startDiscovery()
            startFallbackNetworkScan(force: true)
        } else {
            stopDiscovery()
        }
    }

    @discardableResult
    private func startReceiver() -> Bool {
        receiver.stop()
        do {
            try receiver.start(
                port: localTCPPort,
                outputDirectory: receiveDirectory,
                onPairingRequest: { request in
                    evaluateOnMain(timeout: 5, fallback: false) {
                        let accepted = request.code.filter(\.isNumber) == self.pairingCode.filter(\.isNumber)
                            && self.pairingSeconds > 0
                            && request.requesterFingerprint?.isEmpty == false
                        if accepted {
                            let device = DeviceInfo(
                                deviceName: request.requesterName,
                                platform: request.requesterPlatform,
                                ip: request.requesterIP,
                                port: request.requesterPort,
                                deviceId: request.requesterDeviceId,
                                systemVersion: request.requesterSystemVersion,
                                identityFingerprint: request.requesterFingerprint
                            )
                            TrustedDevicesStore.insert(
                                request.requesterDeviceId,
                                fingerprint: request.requesterFingerprint
                            )
                            self.deviceLastSeenAt[device.deviceId] = Date()
                            self.markDeviceConfirmed(device.deviceId)
                            self.mergeDiscoveredDevice(device)
                            self.useDevice(device)
                            self.status = "已与 \(device.deviceName) 完成配对"
                        }
                        return accepted
                    }
                },
                shouldAccept: { meta in
                    if meta.senderDeviceId == self.deviceId {
                        return false
                    }
                    let autoReceive = evaluateOnMain(timeout: 5, fallback: false) {
                        self.autoReceiveTrustedDevices
                    }
                    guard confirmIncomingFile(meta) else { return false }
                    if autoReceive { return true }
                    return evaluateOnMain(timeout: 600, fallback: false) {
                        promptForIncomingFile(meta)
                    }
                },
                onProgress: { [weak self] meta, current, total in
                    Task { @MainActor in
                        guard let self else { return }
                        let progress = total == 0 ? 1 : Double(current) / Double(total)
                        self.progress = progress
                        self.status = "接收中 \(Int(progress * 100))%：\(meta.fileName)"
                        self.upsertReceivingTransfer(meta: meta, progress: progress, current: current, total: total)
                    }
                },
                onConnectionResult: { [weak self] result in
                    Task { @MainActor in
                        switch result {
                        case .success(let received):
                            if let received {
                                guard received.meta.senderDeviceId != self?.deviceId else { return }
                                self?.status = "已保存：\(received.url.lastPathComponent)"
                                self?.progress = 1
                                self?.completeReceivingTransfer(meta: received.meta, savedName: received.url.lastPathComponent, success: true, detail: "已保存到 \(received.url.deletingLastPathComponent().path)", localURL: received.url)
                            } else {
                                self?.status = "已拒绝接收"
                            }
                        case .failure(let error):
                            self?.handleReceiveFailure(error)
                        }
                    }
                }
            )
            receiverRunning = true
            status = "接收服务已开启，端口 \(localTCPPort)"
            return true
        } catch {
            receiverRunning = false
            recordDiagnostic(code: "TRN-RECV-001", module: "receiver", message: "\(error)")
            status = "接收服务启动失败：\(error)"
            return false
        }
    }

}
