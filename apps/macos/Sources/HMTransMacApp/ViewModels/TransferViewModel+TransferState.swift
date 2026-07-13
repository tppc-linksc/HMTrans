import AppKit
import Foundation
import HMTransCore

/// 将任务状态变更集中管理，使界面操作、持久化和后台活动始终观察到同一次状态转换。
@MainActor
extension TransferViewModel {
    func redactDiagnosticText(_ value: String) -> String {
        value
            .replacingOccurrences(
                of: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#,
                with: "<local-ip>",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"/(?:Users|private|var)/[^\s,;]+"#,
                with: "<local-path>",
                options: .regularExpression
            )
    }

    func retryHistoryItem(_ item: TransferListItem) {
        guard item.direction == .sending,
              item.state == .failed || item.state == .cancelled,
              let path = item.localPath,
              FileManager.default.fileExists(atPath: path) else {
            status = "无法重试：原文件不存在或已移动"
            return
        }
        guard let device = nearbyDevices.first(where: {
            ($0.deviceId == item.deviceId || $0.deviceName == item.peerName) &&
            TrustedDevicesStore.matches($0.deviceId, fingerprint: $0.identityFingerprint)
        }) else {
            status = "请先重新连接 \(item.peerName)"
            return
        }
        historyTransfers.removeAll { $0.id == item.id }
        var resumed = item
        resumed.state = .waiting
        resumed.detail = "用户重试，正在协商断点"
        resumed.updatedAt = Date()
        currentTransfers.insert(resumed, at: 0)
        host = device.ip
        portText = String(device.port)
        selectedTargetDeviceIDs.insert(device.deviceId)
        persistTransfers()
        resumePersistedTransfer(resumed)
    }

    func pauseGroup(containing item: TransferListItem) {
        guard let groupID = item.groupId else {
            togglePause(item)
            return
        }
        let rows = currentTransfers.filter { $0.groupId == groupID }
        let shouldResume = rows.allSatisfy { $0.state == .paused || $0.state == .waiting }
        for row in rows {
            let shouldToggle = shouldResume
                ? (row.state == .paused || row.state == .waiting)
                : row.state != .paused
            if shouldToggle { togglePause(row) }
        }
    }

    func cancelGroup(containing item: TransferListItem) {
        guard let groupID = item.groupId else {
            cancel(item)
            return
        }
        // 取消操作会修改 currentTransfers，因此先创建快照。
        for row in currentTransfers.filter({ $0.groupId == groupID }) { cancel(row) }
    }

    func upsertCurrentTransfer(_ item: TransferListItem) {
        currentTransfers.removeAll { $0.id == item.id }
        currentTransfers.insert(item, at: 0)
        syncBackgroundActivity()
        persistTransfers()
    }

    func updateCurrentTransfer(id: UUID, progress: Double, current: Int64, total: Int64) {
        guard let index = currentTransfers.firstIndex(where: { $0.id == id }) else { return }
        currentTransfers[index].progress = progress
        currentTransfers[index].detail = transferProgressDetail(
            current: current,
            total: total,
            startedAt: currentTransfers[index].startedAt
        )
        if currentTransfers[index].fileSize == 0 { currentTransfers[index].fileSize = total }
        currentTransfers[index].confirmedOffset = current
        currentTransfers[index].updatedAt = Date()
        persistTransfers()
    }

    func updatePreparedTransfer(id: UUID, fileName: String, fileSize: Int64, fileType: String, detail: String) {
        guard let index = currentTransfers.firstIndex(where: { $0.id == id }) else { return }
        currentTransfers[index].fileName = fileName
        currentTransfers[index].fileSize = fileSize
        currentTransfers[index].fileType = fileType
        currentTransfers[index].detail = detail
        currentTransfers[index].updatedAt = Date()
        persistTransfers()
    }

    func markTransferVerifying(id: UUID) {
        guard let index = currentTransfers.firstIndex(where: { $0.id == id }) else { return }
        currentTransfers[index].state = .verifying
        currentTransfers[index].detail = "正在计算 SHA-256，确保原文件完整"
        currentTransfers[index].updatedAt = Date()
        syncBackgroundActivity()
        persistTransfers()
    }

    func markTransferWaiting(id: UUID, detail: String) {
        guard let index = currentTransfers.firstIndex(where: { $0.id == id }) else { return }
        currentTransfers[index].state = .waiting
        currentTransfers[index].detail = detail
        currentTransfers[index].updatedAt = Date()
        syncBackgroundActivity()
        persistTransfers()
    }

    func upsertReceivingTransfer(meta: FileMeta, progress: Double, current: Int64, total: Int64) {
        let id = receivingTransferIds[meta.transferId] ?? UUID()
        if receivingTransferIds[meta.transferId] == nil {
            receivingTransferIds[meta.transferId] = id
            upsertCurrentTransfer(TransferListItem(
                id: id,
                fileName: meta.sourceName ?? meta.fileName,
                peerName: meta.senderName ?? meta.senderPlatform ?? "未知设备",
                direction: .receiving,
                progress: progress,
                detail: transferProgressDetail(current: current, total: total, startedAt: Date()),
                fileSize: meta.fileSize,
                fileType: fileTypeLabel(meta.sourceName ?? meta.fileName)
            ))
        } else {
            updateCurrentTransfer(id: id, progress: progress, current: current, total: total)
        }
    }

    func completeReceivingTransfer(
        meta: FileMeta,
        savedName: String,
        success: Bool,
        detail: String,
        localURL: URL? = nil
    ) {
        let id = receivingTransferIds.removeValue(forKey: meta.transferId) ?? UUID()
        if !currentTransfers.contains(where: { $0.id == id }) {
            upsertCurrentTransfer(TransferListItem(
                id: id,
                fileName: meta.sourceName ?? savedName,
                peerName: meta.senderName ?? meta.senderPlatform ?? "未知设备",
                direction: .receiving,
                progress: success ? 1 : 0,
                detail: detail,
                fileSize: meta.fileSize,
                fileType: fileTypeLabel(meta.sourceName ?? savedName),
                localPath: localURL?.path
            ))
        }
        if let localURL, let index = currentTransfers.firstIndex(where: { $0.id == id }) {
            currentTransfers[index].localPath = localURL.path
        }
        completeTransfer(id: id, success: success, detail: detail)
    }

    func openTransferItem(_ item: TransferListItem) {
        guard item.state == .done, let url = resolvedTransferURL(item) else {
            showMissingTransferFileAlert(item)
            return
        }
        guard NSWorkspace.shared.open(url) else {
            showMissingTransferFileAlert(item)
            return
        }
        status = "已打开：\(item.fileName)"
    }

    func revealTransferItem(_ item: TransferListItem) {
        guard item.state == .done, let url = resolvedTransferURL(item) else {
            showMissingTransferFileAlert(item)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        status = "已在 Finder 中显示：\(item.fileName)"
    }

    func failOldestReceivingTransfer(detail: String) {
        guard let item = currentTransfers.first(where: { $0.direction == .receiving }) else { return }
        receivingTransferIds = receivingTransferIds.filter { $0.value != item.id }
        completeTransfer(id: item.id, success: false, detail: detail)
    }

    func completeTransfer(id: UUID, success: Bool, detail: String) {
        guard let index = currentTransfers.firstIndex(where: { $0.id == id }) else { return }
        var item = currentTransfers.remove(at: index)
        item.progress = success ? 1 : item.progress
        item.detail = transferCompletionDetail(prefix: detail, item: item)
        item.state = success ? .done : .failed
        item.timeText = TransferListItem.nowText()
        syncBackgroundActivity()
        appendHistory(item)
    }

    func handleSystemWillSleep() {
        for (id, control) in transferControls {
            if let index = currentTransfers.firstIndex(where: { $0.id == id }) {
                currentTransfers[index].state = .waiting
                currentTransfers[index].detail = "Mac 即将休眠，已保存断点"
                currentTransfers[index].updatedAt = Date()
            }
            control.cancel()
        }
        transferControls.removeAll()
        backgroundController.setActive(false)
        store.saveImmediately(current: currentTransfers, history: historyTransfers)
    }

    func handleSystemDidWake() {
        status = "Mac 已唤醒，正在恢复设备与任务"
        ensureReceiverAndDiscovery()
        refreshDevices()
    }

    func syncBackgroundActivity() {
        let active = currentTransfers.contains {
            $0.state == .preparing || $0.state == .active || $0.state == .verifying
        }
        backgroundController.setActive(backgroundTransferProtection && active)
    }

    func recordDiagnostic(
        code: String,
        module: String,
        message: String,
        transferID: String? = nil,
        deviceID: String? = nil
    ) {
        store.recordDiagnostic(
            code: code,
            module: module,
            message: message,
            transferID: transferID,
            deviceID: deviceID
        )
    }

    nonisolated static func initialFileSizeForDisplay(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    func appendHistory(_ item: TransferListItem) {
        historyTransfers.insert(item, at: 0)
        persistTransfers()
    }

    func persistTransfers() {
        persistenceTask?.cancel()
        persistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            store.save(current: currentTransfers, history: historyTransfers)
            persistenceTask = nil
        }
    }

    private func resolvedTransferURL(_ item: TransferListItem) -> URL? {
        if let url = item.localURL?.standardizedFileURL,
           FileManager.default.fileExists(atPath: url.path) { return url }
        let candidate = URL(fileURLWithPath: receiveDirectory, isDirectory: true)
            .appendingPathComponent(item.fileName)
            .standardizedFileURL
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private func showMissingTransferFileAlert(_ item: TransferListItem) {
        status = "文件不存在或已被移动：\(item.fileName)"
        let alert = NSAlert()
        alert.messageText = "找不到文件"
        alert.informativeText = "\(item.fileName) 可能已被移动、重命名或删除。历史记录仍会保留。"
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }
}

private func transferProgressDetail(current: Int64, total: Int64, startedAt: Date) -> String {
    guard total > 0 else { return "传输中" }
    let elapsed = max(Date().timeIntervalSince(startedAt), 0.15)
    let speed = Int64(Double(current) / elapsed)
    return "\(formatBytes(current)) / \(formatBytes(total)) · \(formatBytes(speed))/s"
}

private func transferCompletionDetail(prefix: String, item: TransferListItem) -> String {
    let elapsed = max(Date().timeIntervalSince(item.startedAt), 0.15)
    let size = item.fileSize
    let sizeText = size > 0 ? formatBytes(size) : "未知大小"
    let typeText = item.fileType.isEmpty ? fileTypeLabel(item.fileName) : item.fileType
    let averageText = size > 0 ? "\(formatBytes(Int64(Double(size) / elapsed)))/s" : "-"
    return "\(prefix) · \(sizeText) · \(typeText) · 平均 \(averageText)"
}
