import Foundation
import HMTransCore

@MainActor
extension TransferViewModel {
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

    func sendFiles(_ urls: [URL], reusingTransferID: UUID? = nil) {
        let targets = activeTransferTargets
        guard !targets.isEmpty else {
            status = "请先在连接页输入六位配对码并完成配对"
            return
        }
        let groupID = UUID()
        for target in targets {
            sendFiles(
                urls,
                to: target,
                reusingTransferID: targets.count == 1 ? reusingTransferID : nil,
                groupID: groupID
            )
        }
    }

    func toggleTransferTarget(_ device: DeviceInfo) {
        guard TrustedDevicesStore.matches(device.deviceId, fingerprint: device.identityFingerprint) else {
            selectDevice(device)
            return
        }
        if selectedTargetDeviceIDs.contains(device.deviceId), selectedTargetDeviceIDs.count > 1 {
            selectedTargetDeviceIDs.remove(device.deviceId)
            status = "已取消选择：\(device.deviceName)"
        } else {
            selectedTargetDeviceIDs.insert(device.deviceId)
            useDevice(device)
            status = "已选择发送目标：\(device.deviceName)"
        }
    }

    func sendFiles(
        _ urls: [URL],
        to targetDevice: DeviceInfo,
        reusingTransferID: UUID? = nil,
        groupID: UUID? = nil
    ) {
        let targetHost = targetDevice.ip
        let targetPort = targetDevice.port
        guard let targetSharedSecret = TrustedDevicesStore.sharedSecret(for: targetDevice.deviceId) else {
            status = "该设备仍使用旧版配对信息，请移除后重新安全配对"
            return
        }
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
        let senderFingerprint = identityFingerprint
        let generation = transferGeneration
        let progressThrottle = progressUpdateThrottle

        Task.detached { [weak self] in
            guard let gate = self?.sendConcurrencyGate,
                  let sourceStore = self?.sharedPreparedSources else { return }
            await gate.acquire()
            let isCurrentGeneration = await MainActor.run { self?.transferGeneration == generation }
            guard isCurrentGeneration else {
                await gate.release()
                return
            }
            guard tcpPortIsOpen(host: targetHost, port: targetPort, timeout: 0.8) else {
                await MainActor.run {
                    self?.isSending = false
                    self?.progress = 0
                    self?.markDeviceUnreachable(targetDevice, reason: "接收端口不可达")
                }
                await gate.release()
                return
            }

            for (index, url) in urls.enumerated() {
                let transferId = (urls.count == 1 ? reusingTransferID : nil) ?? UUID()
                let control = TransferControl()
                await MainActor.run {
                    self?.transferControls[transferId] = control
                    self?.status = "准备发送 \(index + 1)/\(urls.count)：\(url.lastPathComponent)"
                    if let existingIndex = self?.currentTransfers.firstIndex(where: { $0.id == transferId }) {
                        self?.currentTransfers[existingIndex].state = .preparing
                        self?.currentTransfers[existingIndex].detail = "正在协商断点"
                        self?.currentTransfers[existingIndex].updatedAt = Date()
                        self?.persistTransfers()
                    } else {
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
                                localPath: url.path,
                                deviceId: targetDevice.deviceId,
                                groupId: groupID
                            )
                        )
                    }
                }

                do {
                    let artifactGroupID = groupID ?? transferId
                    let prepared = try sourceStore.acquire(
                        url: url,
                        groupID: artifactGroupID
                    )
                    let preparedSize = Self.initialFileSizeForDisplay(prepared.url)
                    await MainActor.run {
                        self?.status = "发送 \(index + 1)/\(urls.count)：\(prepared.displayName)"
                        self?.updatePreparedTransfer(
                            id: transferId,
                            fileName: prepared.displayName,
                            fileSize: preparedSize,
                            fileType: prepared.sourceKind == "folder" ? "文件夹" : fileTypeLabel(prepared.displayName),
                            detail: prepared.cleanupDirectory == nil ? "准备发送" : "已压缩为 zip，准备发送"
                        )
                        // 多 GB 载荷的哈希计算可能耗时明显，因此在 Core 开始前先展示此阶段。
                        self?.markTransferVerifying(id: transferId)
                    }
                    try sendFile(
                        fileURL: prepared.url,
                        host: targetHost,
                        port: targetPort,
                        transferId: transferId.uuidString,
                        senderDeviceId: senderDeviceId,
                        senderName: senderName,
                        senderPlatform: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
                        sourceKind: prepared.sourceKind,
                        payloadKind: prepared.payloadKind,
                        sourceName: prepared.sourceName,
                        sourceSize: prepared.sourceSize,
                        sourceFileCount: prepared.sourceFileCount,
                        senderFingerprint: senderFingerprint,
                        sharedSecret: targetSharedSecret,
                        control: control,
                        onProgress: { current, total in
                            guard progressThrottle.shouldPublish(
                                id: transferId.uuidString,
                                current: current,
                                total: total
                            ) else { return }
                            Task { @MainActor in
                                if let currentIndex = self?.currentTransfers.firstIndex(where: { $0.id == transferId }) {
                                    self?.currentTransfers[currentIndex].state = .active
                                }
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
                    )
                    await MainActor.run {
                        self?.transferControls.removeValue(forKey: transferId)
                        self?.completeTransfer(id: transferId, success: true, detail: "发送完成")
                        self?.isSending = !(self?.transferControls.isEmpty ?? true)
                    }
                    sourceStore.release(
                        url: url,
                        groupID: artifactGroupID,
                        preserveForResume: false
                    )
                } catch {
                    let wasCancelled = control.isCancelled
                    let shouldWaitForReconnect: Bool
                    if case HMTransError.system = error {
                        shouldWaitForReconnect = true
                    } else if case HMTransError.rejected(let reason) = error,
                              reason.contains("receiver_paused") {
                        shouldWaitForReconnect = true
                    } else {
                        shouldWaitForReconnect = false
                    }
                    await MainActor.run {
                        self?.transferControls.removeValue(forKey: transferId)
                        self?.isSending = !(self?.transferControls.isEmpty ?? true)
                        if wasCancelled {
                            self?.status = "已取消：\(url.lastPathComponent)"
                        } else if shouldWaitForReconnect {
                            self?.status = "连接中断，等待设备恢复：\(url.lastPathComponent)"
                            self?.markTransferWaiting(id: transferId, detail: "连接中断，已保存断点")
                            self?.scheduleAutomaticResume(id: transferId)
                        } else {
                            self?.recordDiagnostic(
                                code: "TRN-SEND-001",
                                module: "send",
                                message: "\(error)",
                                transferID: transferId.uuidString,
                                deviceID: targetDevice.deviceId
                            )
                            self?.status = "发送失败：\(error)"
                            self?.completeTransfer(id: transferId, success: false, detail: "\(error)")
                        }
                    }
                    sourceStore.release(
                        url: url,
                        groupID: groupID ?? transferId,
                        preserveForResume: shouldWaitForReconnect && !wasCancelled
                    )
                    await gate.release()
                    return
                }
            }

            await MainActor.run {
                self?.progress = 1
                self?.isSending = false
                self?.status = "发送完成"
            }
            await gate.release()
        }
    }
}
