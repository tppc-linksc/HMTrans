import AppKit
import Foundation
import Observation
import PureSendCore

@MainActor
@Observable
final class TransferViewModel {
    var host: String = UserDefaults.standard.string(forKey: "lastHost") ?? ""
    var portText: String = UserDefaults.standard.string(forKey: "lastPort") ?? String(defaultPort)
    var selectedFile: URL?
    var receiveDirectory: String = UserDefaults.standard.string(forKey: "receiveDirectory") ?? defaultReceiveDirectory()
    var status: String = "正在启动接收服务"
    var progress: Double = 0
    var isSending: Bool = false
    var receiverRunning: Bool = false
    var nearbyDevices: [DeviceInfo] = []
    var isDropTargeted: Bool = false
    var currentTransfers: [TransferListItem] = []
    var historyTransfers: [TransferListItem] = []

    private let receiver = PersistentFileReceiver()
    private var discovery: DiscoveryService?
    private var didBootstrap = false
    private var lastFallbackScan = Date.distantPast
    private var deviceLastSeenAt: [String: Date] = [:]
    private var receivingTransferIds: [String: UUID] = [:]
    private var pruneTask: Task<Void, Never>?
    private let deviceId: String
    let deviceName: String
    private let discoveredDeviceTTL: TimeInterval = 5

    var port: UInt16 {
        UInt16(portText) ?? defaultPort
    }

    var menuSummary: String {
        if let device = selectedNearbyDevice {
            return "已发现 \(device.deviceName)"
        }
        if !host.isEmpty {
            return "目标 \(host):\(port)"
        }
        return receiverRunning ? "接收服务运行中" : "待机"
    }

    var selectedNearbyDevice: DeviceInfo? {
        nearbyDevices.first { $0.ip == host }
    }

    var connectionTitle: String {
        if let device = selectedNearbyDevice {
            return device.deviceName
        }
        return host.isEmpty ? "未连接设备" : "已保存目标"
    }

    var connectionSubtitle: String {
        if let device = selectedNearbyDevice {
            return "\(device.ip) · Connected"
        }
        if !host.isEmpty {
            return "\(host):\(port) · 等待发现"
        }
        return receiverRunning ? "正在搜索同一 Wi-Fi 设备" : "接收服务未开启"
    }

    var isConnectedToDiscoveredDevice: Bool {
        selectedNearbyDevice != nil
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

        NotificationCenter.default.addObserver(forName: .pureSendOpenFiles, object: nil, queue: .main) { [weak self] notification in
            guard let filenames = notification.object as? [String] else { return }
            Task { @MainActor in
                self?.sendDroppedFiles(filenames.map { URL(fileURLWithPath: $0) })
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        clearLocalSavedTargetIfNeeded()
        startPersistentReceiver()
        startDiscovery()
        startDevicePruning()
        startFallbackNetworkScan()
    }

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
            UserDefaults.standard.set(url.path, forKey: "receiveDirectory")
            status = "接收目录：\(url.path)"
            startPersistentReceiver()
        }
    }

    func selectDevice(_ device: DeviceInfo) {
        useDevice(device, requiresTrustPrompt: true)
    }

    private func autoSelectDevice(_ device: DeviceInfo) {
        useDevice(device, requiresTrustPrompt: false)
    }

    private func useDevice(_ device: DeviceInfo, requiresTrustPrompt: Bool) {
        guard !isLocalIPv4Address(device.ip) else {
            forgetDevice(device)
            status = "已忽略本机地址：\(device.ip)"
            return
        }
        if requiresTrustPrompt {
            guard confirmTrustedConnectionIfNeeded(device) else { return }
        }
        host = device.ip
        portText = String(device.port)
        rememberTarget()
        status = "已选择 \(device.deviceName) \(device.ip)"
    }

    func forgetDevice(_ device: DeviceInfo) {
        TrustedDevicesStore.remove(device.deviceId)
        nearbyDevices.removeAll { $0.deviceId == device.deviceId }
        deviceLastSeenAt.removeValue(forKey: device.deviceId)
        if host == device.ip {
            host = ""
            portText = String(defaultPort)
            rememberTarget()
            status = "已删除设备：\(device.deviceName)"
        }
    }

    func clearSavedTarget() {
        host = ""
        portText = String(defaultPort)
        rememberTarget()
        status = "已清除保存目标"
    }

    private func markDeviceUnreachable(_ device: DeviceInfo, reason: String) {
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

    func sendSelectedFile() {
        guard let selectedFile else {
            status = "请先选择或拖入文件"
            return
        }
        sendFiles([selectedFile])
    }

    func sendDroppedFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        selectedFile = urls.first
        sendFiles(urls)
    }

    func sendFiles(_ urls: [URL]) {
        guard let targetDevice = selectedNearbyDevice else {
            status = "请等待发现并选择 MatePad"
            return
        }
        let targetHost = targetDevice.ip
        let targetPort = targetDevice.port
        guard !isLocalIPv4Address(targetHost) else {
            clearSavedTarget()
            status = "已阻止发送到本机地址，请等待发现 MatePad"
            return
        }

        rememberTarget()
        isSending = true
        progress = 0
        let senderDeviceId = deviceId
        let senderName = deviceName

        Task.detached { [weak self] in
            for (index, url) in urls.enumerated() {
                let transferId = UUID()
                await MainActor.run {
                    self?.status = "准备发送 \(index + 1)/\(urls.count)：\(url.lastPathComponent)"
                    self?.upsertCurrentTransfer(
                        TransferListItem(
                            id: transferId,
                            fileName: url.lastPathComponent,
                            peerName: targetDevice.deviceName,
                            direction: .sending,
                            progress: 0,
                            detail: "准备发送",
                            fileSize: Self.initialFileSizeForDisplay(url),
                            fileType: fileTypeLabel(url.lastPathComponent),
                            localPath: url.path
                        )
                    )
                }

                do {
                    let prepared = try prepareSendFileForTransfer(url)
                    defer { prepared.cleanup() }
                    let preparedSize = Self.initialFileSizeForDisplay(prepared.url)
                    await MainActor.run {
                        self?.status = "发送 \(index + 1)/\(urls.count)：\(prepared.displayName)"
                        self?.updatePreparedTransfer(
                            id: transferId,
                            fileName: prepared.displayName,
                            fileSize: preparedSize,
                            fileType: fileTypeLabel(prepared.displayName),
                            detail: prepared.cleanupDirectory == nil ? "准备发送" : "已压缩为 zip，准备发送"
                        )
                    }
                    try sendFile(
                        fileURL: prepared.url,
                        host: targetHost,
                        port: targetPort,
                        senderDeviceId: senderDeviceId,
                        senderName: senderName,
                        senderPlatform: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
                    ) { current, total in
                        Task { @MainActor in
                            self?.progress = total == 0 ? 1 : Double(current) / Double(total)
                            self?.status = "发送中 \(Int((self?.progress ?? 0) * 100))%：\(prepared.displayName)"
                            self?.updateCurrentTransfer(
                                id: transferId,
                                progress: self?.progress ?? 0,
                                current: current,
                                total: total
                            )
                        }
                    }
                    await MainActor.run {
                        self?.completeTransfer(id: transferId, success: true, detail: "发送完成")
                    }
                } catch {
                    await MainActor.run {
                        self?.status = "发送失败：\(error)"
                        self?.isSending = false
                        self?.completeTransfer(id: transferId, success: false, detail: "\(error)")
                    }
                    return
                }
            }

            await MainActor.run {
                self?.progress = 1
                self?.isSending = false
                self?.status = "发送完成"
            }
        }
    }

    func startPersistentReceiver() {
        receiver.stop()
        do {
            try receiver.start(
                port: port,
                outputDirectory: receiveDirectory,
                shouldAccept: { meta in
                    if meta.senderDeviceId == self.deviceId {
                        return false
                    }
                    return confirmIncomingFile(meta)
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
                            self?.status = "接收错误：\(error)"
                            self?.failOldestReceivingTransfer(detail: "\(error)")
                        }
                    }
                }
            )
            receiverRunning = true
            status = "接收服务已开启，端口 \(port)"
        } catch {
            receiverRunning = false
            status = "接收服务启动失败：\(error)"
        }
    }

    private func startDiscovery() {
        discovery?.stop()
        let service = DiscoveryService(transferPort: port, deviceId: deviceId)
        discovery = service
        do {
            try service.start { [weak self] device in
                Task { @MainActor in
                    guard let self else { return }
                    self.deviceLastSeenAt[device.deviceId] = Date()
                    var devices = self.nearbyDevices.filter { $0.deviceId != device.deviceId && $0.ip != device.ip }
                    devices.append(device)
                    devices.sort { $0.deviceName < $1.deviceName }
                    self.nearbyDevices = devices

                    if self.host.isEmpty ||
                        self.host == device.ip ||
                        TrustedDevicesStore.contains(device.deviceId) ||
                        UserDefaults.standard.bool(forKey: "autoUseDiscoveredDevice") {
                        self.autoSelectDevice(device)
                        UserDefaults.standard.set(true, forKey: "autoUseDiscoveredDevice")
                    }
                }
            }
        } catch {
            status = "设备发现启动失败：\(error)"
        }
    }

    private func startDevicePruning() {
        guard pruneTask == nil else { return }
        pruneTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.pruneStaleDevices()
                self?.startFallbackNetworkScan()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func pruneStaleDevices() {
        let now = Date()
        let freshDevices = nearbyDevices.filter { device in
            guard let lastSeen = deviceLastSeenAt[device.deviceId] else { return false }
            return now.timeIntervalSince(lastSeen) < discoveredDeviceTTL
        }
        guard freshDevices.count != nearbyDevices.count else { return }
        nearbyDevices = freshDevices
        let freshIds = Set(freshDevices.map(\.deviceId))
        deviceLastSeenAt = deviceLastSeenAt.filter { freshIds.contains($0.key) }
    }

    private func startFallbackNetworkScan(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastFallbackScan) > 8 else { return }
        lastFallbackScan = now

        let targetPort = port
        let candidates = fallbackScanCandidates(savedHost: host)
        guard !candidates.isEmpty else { return }

        Task.detached { [weak self] in
            await withTaskGroup(of: String?.self) { group in
                for ip in candidates {
                    group.addTask {
                        tcpPortIsOpen(host: ip, port: targetPort, timeout: 0.22) ? ip : nil
                    }
                }

                for await ip in group {
                    guard let ip else { continue }
                    await MainActor.run {
                        self?.mergeFallbackDevice(ip: ip, port: targetPort)
                    }
                }
            }
        }
    }

    private func mergeFallbackDevice(ip: String, port: UInt16) {
        guard !isLocalIPv4Address(ip) else {
            if host == ip {
                clearSavedTarget()
            }
            return
        }
        if let existing = nearbyDevices.first(where: { $0.ip == ip }) {
            deviceLastSeenAt[existing.deviceId] = Date()
            return
        }
        let device = DeviceInfo(
            deviceName: "MatePad",
            platform: "HarmonyOS",
            ip: ip,
            port: port,
            deviceId: "tcp-\(ip)-\(port)"
        )
        nearbyDevices.append(device)
        deviceLastSeenAt[device.deviceId] = Date()
        nearbyDevices.sort { $0.deviceName < $1.deviceName }

        if host.isEmpty || host == ip {
            autoSelectDevice(device)
            UserDefaults.standard.set(true, forKey: "autoUseDiscoveredDevice")
        }
    }

    private func rememberTarget() {
        UserDefaults.standard.set(host, forKey: "lastHost")
        UserDefaults.standard.set(portText, forKey: "lastPort")
    }

    private func clearLocalSavedTargetIfNeeded() {
        if isLocalIPv4Address(host) {
            host = ""
            portText = String(defaultPort)
            rememberTarget()
            status = "已清除本机保存地址"
        }
    }

    private func confirmTrustedConnectionIfNeeded(_ device: DeviceInfo) -> Bool {
        if TrustedDevicesStore.contains(device.deviceId) {
            return true
        }

        let alert = NSAlert()
        alert.messageText = "连接并信任 \(device.deviceName)？"
        alert.informativeText = "\(device.platform)\n\(device.ip):\(device.port)\n首次连接需要确认，信任后下次会自动连接。删除信任后重新连接会再次确认。"
        alert.addButton(withTitle: "信任并连接")
        alert.addButton(withTitle: "取消")
        let accepted = alert.runModal() == .alertFirstButtonReturn
        if accepted {
            TrustedDevicesStore.insert(device.deviceId)
        }
        return accepted
    }

    private func upsertCurrentTransfer(_ item: TransferListItem) {
        currentTransfers.removeAll { $0.id == item.id }
        currentTransfers.insert(item, at: 0)
    }

    private func updateCurrentTransfer(id: UUID, progress: Double, current: Int64, total: Int64) {
        guard let index = currentTransfers.firstIndex(where: { $0.id == id }) else { return }
        currentTransfers[index].progress = progress
        currentTransfers[index].detail = progressDetail(current: current, total: total, startedAt: currentTransfers[index].startedAt)
        if currentTransfers[index].fileSize == 0 {
            currentTransfers[index].fileSize = total
        }
    }

    private func updatePreparedTransfer(id: UUID, fileName: String, fileSize: Int64, fileType: String, detail: String) {
        guard let index = currentTransfers.firstIndex(where: { $0.id == id }) else { return }
        currentTransfers[index].fileName = fileName
        currentTransfers[index].fileSize = fileSize
        currentTransfers[index].fileType = fileType
        currentTransfers[index].detail = detail
    }

    private func upsertReceivingTransfer(meta: FileMeta, progress: Double, current: Int64, total: Int64) {
        let id = receivingTransferIds[meta.transferId] ?? UUID()
        if receivingTransferIds[meta.transferId] == nil {
            receivingTransferIds[meta.transferId] = id
            upsertCurrentTransfer(
                TransferListItem(
                    id: id,
                    fileName: meta.fileName,
                    peerName: meta.senderName ?? meta.senderPlatform ?? "未知设备",
                    direction: .receiving,
                    progress: progress,
                    detail: progressDetail(current: current, total: total, startedAt: Date()),
                    fileSize: meta.fileSize,
                    fileType: fileTypeLabel(meta.fileName)
                )
            )
        } else {
            updateCurrentTransfer(id: id, progress: progress, current: current, total: total)
        }
    }

    private func completeReceivingTransfer(meta: FileMeta, savedName: String, success: Bool, detail: String, localURL: URL? = nil) {
        let id = receivingTransferIds.removeValue(forKey: meta.transferId) ?? UUID()
        if !currentTransfers.contains(where: { $0.id == id }) {
            upsertCurrentTransfer(
                TransferListItem(
                    id: id,
                    fileName: savedName,
                    peerName: meta.senderName ?? meta.senderPlatform ?? "未知设备",
                    direction: .receiving,
                    progress: success ? 1 : 0,
                    detail: detail,
                    fileSize: meta.fileSize,
                    fileType: fileTypeLabel(savedName),
                    localPath: localURL?.path
                )
            )
        }
        if let localURL, let index = currentTransfers.firstIndex(where: { $0.id == id }) {
            currentTransfers[index].localPath = localURL.path
        }
        completeTransfer(id: id, success: success, detail: detail)
    }

    func openTransferItem(_ item: TransferListItem) {
        guard item.state == .done, let url = item.localURL else {
            status = "该记录没有可打开的本地文件"
            return
        }
        NSWorkspace.shared.open(url)
    }

    func revealTransferItem(_ item: TransferListItem) {
        guard item.state == .done, let url = item.localURL else {
            status = "该记录没有可定位的本地文件"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func failOldestReceivingTransfer(detail: String) {
        guard let item = currentTransfers.first(where: { $0.direction == .receiving }) else { return }
        receivingTransferIds = receivingTransferIds.filter { $0.value != item.id }
        completeTransfer(id: item.id, success: false, detail: detail)
    }

    private func completeTransfer(id: UUID, success: Bool, detail: String) {
        guard let index = currentTransfers.firstIndex(where: { $0.id == id }) else { return }
        var item = currentTransfers.remove(at: index)
        item.progress = success ? 1 : item.progress
        item.detail = completionDetail(prefix: detail, item: item)
        item.state = success ? .done : .failed
        item.timeText = TransferListItem.nowText()
        appendHistory(item)
    }


nonisolated private static func initialFileSizeForDisplay(_ url: URL) -> Int64 {
    guard let number = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
        return 0
    }
    return number.int64Value
}

private func progressDetail(current: Int64, total: Int64, startedAt: Date) -> String {
    guard total > 0 else { return "传输中" }
    let elapsed = max(Date().timeIntervalSince(startedAt), 0.15)
    let speed = Int64(Double(current) / elapsed)
    return "\(formatBytes(current)) / \(formatBytes(total)) · \(formatBytes(speed))/s"
}

private func completionDetail(prefix: String, item: TransferListItem) -> String {
    let elapsed = max(Date().timeIntervalSince(item.startedAt), 0.15)
    let size = item.fileSize > 0 ? item.fileSize : Int64(max(item.progress, 0) * 0)
    let sizeText = size > 0 ? formatBytes(size) : "未知大小"
    let typeText = item.fileType.isEmpty ? fileTypeLabel(item.fileName) : item.fileType
    let averageText = size > 0 ? "\(formatBytes(Int64(Double(size) / elapsed)))/s" : "-"
    return "\(prefix) · \(sizeText) · \(typeText) · 平均 \(averageText)"
}

    private func appendHistory(_ item: TransferListItem) {
        historyTransfers.insert(item, at: 0)
        if historyTransfers.count > 30 {
            historyTransfers.removeLast(historyTransfers.count - 30)
        }
    }
}
