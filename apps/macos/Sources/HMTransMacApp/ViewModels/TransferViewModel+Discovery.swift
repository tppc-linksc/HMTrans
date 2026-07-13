import Foundation
import HMTransCore

/// 设备发现与身份去重独立于传输状态，确保回退 TCP 探测不会创建第二个物理设备。
@MainActor
extension TransferViewModel {
    @discardableResult
    func startDiscovery() -> Bool {
        guard discoveryEnabled else {
            stopDiscovery()
            return false
        }
        discovery?.stop()
        let service = DiscoveryService(
            transferPort: localTCPPort,
            discoveryPort: localDiscoveryPort,
            deviceId: deviceId,
            identityFingerprint: identityFingerprint
        )
        discovery = service
        do {
            try service.start { [weak self] device in
                Task { @MainActor in
                    guard let self, self.discoveryEnabled else {
                        self?.stopDiscovery()
                        return
                    }
                    self.mergeDiscoveredDevice(device)
                    if TrustedDevicesStore.matches(device.deviceId, fingerprint: device.identityFingerprint)
                        && self.isBidirectionallyConnected(device) {
                        self.autoSelectDevice(device)
                    }
                }
            }
            return true
        } catch {
            discovery = nil
            recordDiagnostic(code: "TRN-DISC-001", module: "discovery", message: "\(error)")
            status = "设备发现启动失败：\(error)"
            return false
        }
    }

    func stopDiscovery() {
        discovery?.stop()
        discovery = nil
        nearbyDevices = []
        deviceLastSeenAt = [:]
        confirmedDeviceLastSeenAt = [:]
        connectedDeviceIDs = []
    }

    func mergeDiscoveredDevice(_ incoming: DeviceInfo) {
        // 缺少身份数据只表示数据包未验证，不代表已配对安装更换了身份。
        // 仅当对端提供明确且不同于本地记录的指纹时才撤销信任。
        if TrustedDevicesStore.contains(incoming.deviceId),
           let fingerprint = incoming.identityFingerprint,
           !fingerprint.isEmpty,
           !TrustedDevicesStore.matches(incoming.deviceId, fingerprint: fingerprint) {
            TrustedDevicesStore.remove(incoming.deviceId)
            selectedTargetDeviceIDs.remove(incoming.deviceId)
            status = "设备身份已变化，请重新配对：\(incoming.deviceName)"
            recordDiagnostic(
                code: "PAIR-IDENTITY-CHANGED",
                module: "pairing",
                message: "stored fingerprint mismatch",
                deviceID: incoming.deviceId
            )
        }
        let matches = nearbyDevices.filter { discoveredDevice($0, matches: incoming) }

        nearbyDevices.removeAll { discoveredDevice($0, matches: incoming) }
        nearbyDevices.append(incoming)
        nearbyDevices.sort { $0.deviceName.localizedCaseInsensitiveCompare($1.deviceName) == .orderedAscending }
        for match in matches { deviceLastSeenAt.removeValue(forKey: match.deviceId) }
        deviceLastSeenAt[incoming.deviceId] = Date()
        let acknowledgementMatches = incoming.acknowledgedDeviceId == deviceId
        if acknowledgementMatches {
            markDeviceConfirmed(incoming.deviceId)
        }
        persist(device: incoming)
    }

    func handleReceiveFailure(_ error: Error) {
        let detail = "\(error)"
        if detail.contains("监听失败") {
            receiverRunning = false
            status = "接收服务中断，自动发现仍保持运行：\(detail)"
            return
        }
        status = "接收错误：\(detail)"
        recordDiagnostic(code: "TRN-RECV-002", module: "receiver", message: detail)
        guard let connectionError = error as? ReceiveConnectionError,
              let itemID = receivingTransferIds[connectionError.transferID],
              let item = currentTransfers.first(where: { $0.id == itemID }),
              item.state != .paused, item.state != .waiting else { return }
        markTransferWaiting(id: item.id, detail: "接收连接中断，分片已保留")
    }

    func receivingWireID(for itemID: UUID) -> String? {
        receivingTransferIds.first(where: { $0.value == itemID })?.key
    }

    func scheduleAutomaticResume(id: UUID) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self,
                  let item = currentTransfers.first(where: { $0.id == id && $0.state == .waiting }),
                  matchingNearbyDevice(for: item) != nil,
                  transferControls[id] == nil else { return }
            resumePersistedTransfer(item)
        }
    }

    func startDevicePruning() {
        guard pruneTask == nil else { return }
        pruneTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.pruneStaleDevices()
                self?.startFallbackNetworkScan()
                // 四秒一次可避免旧实现每秒唤醒一次空闲应用。
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    func startFallbackNetworkScan(force: Bool = false) {
        guard discoveryEnabled else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastFallbackScan) > 12 else { return }
        lastFallbackScan = now
        let targetPort = port
        let candidates = fallbackScanCandidates(savedHost: host)
        guard !candidates.isEmpty else { return }
        Task.detached { [weak self] in
            await withTaskGroup(of: String?.self) { group in
                for ip in candidates {
                    group.addTask { tcpPortIsOpen(host: ip, port: targetPort, timeout: 0.22) ? ip : nil }
                }
                for await ip in group {
                    guard let ip else { continue }
                    await MainActor.run { self?.mergeFallbackDevice(ip: ip, port: targetPort) }
                }
            }
        }
    }

    func rememberTarget() {
        UserDefaults.standard.set(host, forKey: "lastHost")
        UserDefaults.standard.set(portText, forKey: "lastPort")
    }

    func clearLocalSavedTargetIfNeeded() {
        guard isLocalIPv4Address(host) else { return }
        host = ""
        portText = String(defaultPort)
        rememberTarget()
        status = "已清除本机保存地址"
    }

    func persist(device: DeviceInfo) {
        let saved = PersistedDevice(
            id: device.deviceId,
            name: device.deviceName,
            platform: device.platform,
            systemVersion: device.systemVersion ?? "未知版本",
            address: device.ip,
            port: device.port,
            isPaired: TrustedDevicesStore.contains(device.deviceId),
            lastSeenAt: Date()
        )
        let duplicates = persistedDevices.filter { persistedDevice($0, matches: device) && $0.id != saved.id }
        for duplicate in duplicates { store.removeDevice(id: duplicate.id) }
        persistedDevices.removeAll { $0.id == saved.id || persistedDevice($0, matches: device) }
        persistedDevices.insert(saved, at: 0)
        store.upsert(device: saved)
    }

    private func pruneStaleDevices() {
        let now = Date()
        nearbyDevices = nearbyDevices.filter {
            guard let lastSeen = deviceLastSeenAt[$0.deviceId] else { return false }
            return now.timeIntervalSince(lastSeen) < discoveredDeviceTTL
        }
        let ids = Set(nearbyDevices.map(\.deviceId))
        deviceLastSeenAt = deviceLastSeenAt.filter { ids.contains($0.key) }
        confirmedDeviceLastSeenAt = confirmedDeviceLastSeenAt.filter {
            ids.contains($0.key) && now.timeIntervalSince($0.value) < discoveredDeviceTTL
        }
        connectedDeviceIDs = Set(confirmedDeviceLastSeenAt.keys)
    }

    private func mergeFallbackDevice(ip: String, port _: UInt16) {
        guard !isLocalIPv4Address(ip) else { return }
        if let existing = nearbyDevices.first(where: { $0.ip == ip }) {
            deviceLastSeenAt[existing.deviceId] = Date()
        }
        // TCP 探测成功并不提供稳定设备 ID 或指纹。它可以刷新已发现设备，
        // 但绝不能伪造第二个可点击并再次要求配对的设备。
    }

    private func discoveredDevice(_ lhs: DeviceInfo, matches rhs: DeviceInfo) -> Bool {
        lhs.deviceId == rhs.deviceId || lhs.ip == rhs.ip
    }

    private func persistedDevice(_ lhs: PersistedDevice, matches rhs: DeviceInfo) -> Bool {
        lhs.id == rhs.deviceId || lhs.address == rhs.ip
    }
}
