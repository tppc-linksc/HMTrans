import AppKit
import CoreLocation
import CoreWLAN
import HMTransCore
import SwiftUI

private enum MacSection: String, CaseIterable, Identifiable {
    case connection = "连接"
    case history = "历史"
    case settings = "设置"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .connection: "rectangle.connected.to.line.below"
        case .history: "doc.text"
        case .settings: "gearshape"
        }
    }
}

struct V02RootView: View {
    let model: TransferViewModel
    @State private var section: MacSection = .connection

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            ZStack {
                MacAppTheme.windowBackground
                Group {
                    switch section {
                    case .connection: MacConnectionPage(model: model)
                    case .history: MacHistoryPage(model: model)
                    case .settings: MacSettingsPage(model: model)
                    }
                }
                .padding(24)
            }
        }
        .background(MacAppTheme.windowBackground)
    }

    private var sidebar: some View {
        VStack(spacing: 18) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("HM互传").font(.system(size: 14, weight: .bold))
                    Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.0")")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)

            VStack(spacing: 6) {
                ForEach(MacSection.allCases) { item in
                    Button {
                        section = item
                    } label: {
                        HStack(spacing: 11) {
                            Image(systemName: item.icon).frame(width: 22)
                            Text(item.rawValue)
                            Spacer()
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(section == item ? MacAppTheme.accent : Color.primary.opacity(0.72))
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42, alignment: .leading)
                        .contentShape(Rectangle())
                        .background(section == item ? MacAppTheme.elevatedSurface : .clear, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .accessibilityLabel("切换到\(item.rawValue)页面")
                }
            }

            Spacer()
        }
        .padding(18)
        .frame(width: 184)
        .background(.ultraThinMaterial)
        .overlay(alignment: .trailing) { Rectangle().fill(MacAppTheme.subtleBorder).frame(width: 1) }
    }
}

private struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 27, weight: .bold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
    }
}

private struct MacConnectionPage: View {
    let model: TransferViewModel
    @StateObject private var wifiNameProvider = WiFiNameProvider()

    private var displayedDevices: [DeviceInfo] {
        var result: [DeviceInfo] = []
        for device in model.nearbyDevices.sorted(by: deviceDisplayOrder) {
            if let index = result.firstIndex(where: { devicesRepresentSameHardware($0, device) }) {
                if TrustedDevicesStore.contains(device.deviceId), !TrustedDevicesStore.contains(result[index].deviceId) {
                    result[index] = device
                }
            } else {
                result.append(device)
            }
        }
        return result
    }
    private var connected: [DeviceInfo] {
        displayedDevices.filter {
            TrustedDevicesStore.matches($0.deviceId, fingerprint: $0.identityFingerprint)
                && model.isBidirectionallyConnected($0)
        }
    }
    private var nearby: [DeviceInfo] {
        displayedDevices.filter { !TrustedDevicesStore.contains($0.deviceId) }
    }
    private var offline: [PersistedDevice] {
        let online = connected
        var result: [PersistedDevice] = []
        for device in model.persistedDevices where TrustedDevicesStore.contains(device.id) {
            guard !online.contains(where: { persistedDevice(device, represents: $0) }) else { continue }
            guard !result.contains(where: { persistedDevicesRepresentSameHardware($0, device) }) else { continue }
            result.append(device)
        }
        return result
    }
    private var networkDisplayName: String {
        wifiNameProvider.name ?? model.nearbyDevices.compactMap(\.networkName).first ?? "当前局域网"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                PageHeader(title: "连接", subtitle: "管理设备发现、连接与配对，并向已连接设备发送文件。") { EmptyView() }

                HStack(spacing: 12) {
                    infoCard(
                        title: "当前网络",
                        value: networkDisplayName,
                        detail: localIPv4Addresses().first ?? "正在获取本机地址",
                        systemImage: "wifi"
                    )
                    pairingCard
                }

                nearbyDeviceSection
                MacFileDrop(model: model)
            }
        }
        .onAppear { wifiNameProvider.start() }
    }

    private func infoCard(title: String, value: String, detail: String, systemImage: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).foregroundStyle(.secondary).font(.system(size: 10, weight: .semibold))
            HStack(spacing: 7) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(MacAppTheme.accent)
                }
                Text(value).font(.system(size: 17, weight: .bold))
            }
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(18).frame(maxWidth: .infinity, minHeight: 110, maxHeight: 110, alignment: .leading).glassCard(radius: 16)
    }

    private var pairingCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("本机配对码").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(model.pairingCode).font(.system(size: 27, weight: .bold, design: .rounded)).tracking(4).foregroundStyle(MacAppTheme.accent)
                Text("在对方设备输入六位码完成首次配对").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: model.regeneratePairingCode) {
                ZStack {
                    Circle().stroke(MacAppTheme.subtleBorder, lineWidth: 3)
                    Circle().trim(from: 0, to: Double(model.pairingSeconds) / 180).stroke(MacAppTheme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                    Text("\(model.pairingSeconds)").font(.system(size: 11, weight: .bold))
                }.frame(width: 56, height: 56)
            }.buttonStyle(.plain)
                .accessibilityLabel("配对码剩余 \(model.pairingSeconds) 秒")
                .accessibilityHint("立即生成新的六位配对码")
        }
        .padding(18).frame(maxWidth: .infinity, minHeight: 110, maxHeight: 110).glassCard(radius: 16)
    }

    private var nearbyDeviceSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("附近设备").font(.system(size: 15, weight: .bold))
                }
                Spacer()
                Text("\(connected.count + offline.count + nearby.count) 台").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if connected.isEmpty && offline.isEmpty && nearby.isEmpty {
                Text(model.discoveryEnabled ? "暂无设备" : "连接已关闭，已配对设备将在重新开启后自动连接")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 54)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                    // 同一台物理设备会在这些分组之间移动。
                    // 带命名空间的身份可防止模型变为已连接后，SwiftUI 仍复用离线卡片。
                    ForEach(connected) { device in
                        deviceCard(device, state: .alive).id("connected-\(device.deviceId)")
                    }
                    ForEach(offline) { device in
                        persistedDeviceCard(device).id("offline-\(device.id)")
                    }
                    ForEach(nearby) { device in
                        deviceCard(device, state: .new).id("nearby-\(device.deviceId)")
                    }
                }
            }
        }
        .padding(16)
        .glassCard(radius: 17)
    }

    private enum DeviceVisualState { case alive, new }

    private func deviceCard(_ device: DeviceInfo, state: DeviceVisualState) -> some View {
        Button {
            if state == .alive { model.toggleTransferTarget(device) } else { model.selectDevice(device) }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: device.platform == "macOS" ? "laptopcomputer" : "ipad").font(.system(size: 22)).foregroundStyle(state == .alive ? .green : MacAppTheme.accent).frame(width: 44, height: 40).background(state == .alive ? Color.green.opacity(0.10) : MacAppTheme.softSurface, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 5) {
                    Text(device.deviceName).font(.system(size: 13, weight: .bold))
                    Text(deviceSystemDescription(platform: device.platform, version: device.systemVersion))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                    Text(state == .alive ? "已连接" : "新设备 · 点击输入配对码")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(state == .alive ? .green : .secondary)
                }
                Spacer()
                if state == .alive {
                    Image(systemName: model.selectedTargetDeviceIDs.contains(device.deviceId) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(model.selectedTargetDeviceIDs.contains(device.deviceId) ? MacAppTheme.accent : .green)
                }
            }
            .padding(14).frame(minHeight: 96)
            .background(state == .alive ? Color.green.opacity(0.08) : MacAppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(
                model.selectedTargetDeviceIDs.contains(device.deviceId) ? MacAppTheme.accent : (state == .alive ? Color.green.opacity(0.34) : MacAppTheme.subtleBorder),
                lineWidth: model.selectedTargetDeviceIDs.contains(device.deviceId) ? 1.5 : 1
            ))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if state == .alive {
                Button("移除配对设备", role: .destructive) {
                    if confirmForgetDevice(named: device.deviceName) {
                        model.forgetDevice(device)
                    }
                }
            }
        }
        .accessibilityLabel("\(device.deviceName)，\(state == .alive ? "已连接" : "新设备，需要输入配对码")")
        .accessibilityHint(state == .alive ? "选择或取消文件发送目标" : "输入配对码并连接")
    }

    private func persistedDeviceCard(_ device: PersistedDevice) -> some View {
        Button { model.reconnectPersistedDevice(device) } label: { HStack(spacing: 11) {
            Image(systemName: device.platform == "macOS" ? "laptopcomputer" : "ipad").font(.system(size: 22)).foregroundStyle(MacAppTheme.accent).frame(width: 44, height: 40).background(MacAppTheme.blueSurface, in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 5) {
                Text(device.name).font(.system(size: 13, weight: .bold))
                Text(deviceSystemDescription(platform: device.platform, version: device.systemVersion))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                Text("已配对 · 点击重新连接").font(.system(size: 10, weight: .semibold)).foregroundStyle(MacAppTheme.accent)
            }
            Spacer()
        }
        .padding(14).frame(minHeight: 96)
        .background(MacAppTheme.blueSurface, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(MacAppTheme.accent.opacity(0.26), lineWidth: 1)) }
        .buttonStyle(.plain)
        .contextMenu {
            Button("移除配对设备", role: .destructive) {
                if confirmForgetDevice(named: device.name) {
                    model.forgetPersistedDevice(device)
                }
            }
        }
        .accessibilityLabel("\(device.name)，已配对但未连接")
        .accessibilityHint("重新连接此设备")
    }
}

@MainActor
private final class WiFiNameProvider: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var name: String?
    private let locationManager = CLLocationManager()

    override init() {
        super.init()
        locationManager.delegate = self
    }

    func start() {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
        refresh()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        refresh()
    }

    private func refresh() {
        let value = CWWiFiClient.shared().interface()?.ssid()?.trimmingCharacters(in: .whitespacesAndNewlines)
        name = value?.isEmpty == false ? value : nil
    }
}

private func devicesRepresentSameHardware(_ lhs: DeviceInfo, _ rhs: DeviceInfo) -> Bool {
    lhs.deviceId == rhs.deviceId
        || lhs.ip == rhs.ip
}

private func persistedDevice(_ lhs: PersistedDevice, represents rhs: DeviceInfo) -> Bool {
    lhs.id == rhs.deviceId
        || lhs.address == rhs.ip
}

private func persistedDevicesRepresentSameHardware(_ lhs: PersistedDevice, _ rhs: PersistedDevice) -> Bool {
    lhs.id == rhs.id
        || lhs.address == rhs.address
}

private func deviceDisplayOrder(_ lhs: DeviceInfo, _ rhs: DeviceInfo) -> Bool {
    let lhsTrusted = TrustedDevicesStore.contains(lhs.deviceId)
    let rhsTrusted = TrustedDevicesStore.contains(rhs.deviceId)
    if lhsTrusted != rhsTrusted { return lhsTrusted }
    return lhs.deviceName.localizedCaseInsensitiveCompare(rhs.deviceName) == .orderedAscending
}

private func deviceSystemDescription(platform: String, version: String?) -> String {
    let value = version?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !value.isEmpty, value != "未知版本" else { return platform }
    if value.localizedCaseInsensitiveContains(platform) { return value }
    return "\(platform) \(value)"
}

private struct LiquidIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 36, height: 36)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1))
            .shadow(color: MacAppTheme.softShadow, radius: 9, y: 5)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

private struct MacHistoryPage: View {
    let model: TransferViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                PageHeader(title: "历史", subtitle: "按状态查看全部传输，记录只会在右键删除或清空时移除。") { EmptyView() }
                MacTransferHistoryContent(model: model)
            }
        }
    }
}

private struct MacFileDrop: View {
    let model: TransferViewModel

    private var connectedTargets: [DeviceInfo] {
        // 只有完成双向心跳确认的设备才能启用发送区；“已配对但离线”不能作为兜底目标。
        model.activeTransferTargets
    }

    private var targetLabel: String {
        if connectedTargets.count == 1, let target = connectedTargets.first {
            return "发送给 \(target.deviceName)"
        }
        if connectedTargets.count > 1 {
            return "发送给 \(connectedTargets.count) 台已连接设备"
        }
        return "请先选择已连接设备"
    }

    var body: some View {
        Button(action: model.chooseFile) {
            VStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(MacAppTheme.accent)
                    .frame(width: 54, height: 54)
                    .background(MacAppTheme.blueSurface, in: RoundedRectangle(cornerRadius: 16))
                VStack(spacing: 6) {
                    Text("拖入文件或文件夹").font(.system(size: 16, weight: .bold))
                    Text(targetLabel)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 230)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(MacAppTheme.activeBorder, style: StrokeStyle(lineWidth: 1.3, dash: [7, 5])))
        }
        .buttonStyle(.plain)
        .disabled(connectedTargets.isEmpty)
        .accessibilityLabel(connectedTargets.isEmpty ? "尚未选择已连接设备" : "选择文件或文件夹，\(targetLabel)")
        .dropDestination(for: URL.self) { urls, _ in
            model.sendDroppedFiles(urls)
            return true
        }
    }
}

private enum HistoryStatusFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case transferring = "传输中"
    case done = "已完成"
    case failed = "失败"
    case cancelled = "已取消"
    var id: String { rawValue }
}

private struct TaskControlRow: View {
    let model: TransferViewModel
    let item: TransferListItem
    var body: some View {
        HStack(spacing: 12) {
            Text(item.fileType.isEmpty ? "FILE" : item.fileType).font(.system(size: 10, weight: .bold)).foregroundStyle(MacAppTheme.accent).frame(width: 42, height: 42).background(MacAppTheme.blueSurface, in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 5) { Text(item.fileName).font(.system(size: 13, weight: .bold)).lineLimit(1); Text("\(item.direction.rawValue)到 \(item.peerName) · \(item.detail)").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1) }.frame(maxWidth: .infinity, alignment: .leading)
            ProgressView(value: item.progress).frame(width: 180)
            Text(item.state.rawValue).font(.system(size: 10, weight: .semibold)).frame(width: 64)
            Button { model.togglePause(item) } label: { Image(systemName: item.state == .paused ? "play.fill" : "pause.fill") }
                .buttonStyle(LiquidIconButtonStyle())
                .accessibilityLabel(item.state == .paused ? "继续 \(item.fileName)" : "暂停 \(item.fileName)")
            Button { model.cancel(item) } label: { Image(systemName: "xmark") }
                .buttonStyle(LiquidIconButtonStyle())
                .accessibilityLabel("取消 \(item.fileName)")
        }
        .padding(12)
        .glassCard(radius: 16)
        .contextMenu {
            if item.groupId != nil {
                Button("暂停/继续整个发送组") { model.pauseGroup(containing: item) }
                Button("取消整个发送组", role: .destructive) { model.cancelGroup(containing: item) }
            }
            Button(item.state == .paused ? "继续此任务" : "暂停此任务") { model.togglePause(item) }
            Button("取消此任务", role: .destructive) { model.cancel(item) }
            Button("取消并删除可恢复数据", role: .destructive) { model.cancel(item, deletePartial: true) }
        }
    }
}

private struct HistoryClearTarget: Equatable {
    let key: String
    let name: String
}

private struct MacTransferHistoryContent: View {
    let model: TransferViewModel
    @State private var filter: HistoryStatusFilter = .all
    @State private var confirmingClearAll = false
    @State private var pendingClearPeer: HistoryClearTarget?
    private var filtered: [TransferListItem] {
        let items: [TransferListItem]
        switch filter {
        case .all:
            items = model.currentTransfers + model.historyTransfers
        case .transferring:
            items = model.currentTransfers
        case .done:
            items = model.historyTransfers.filter { $0.state == .done }
        case .failed:
            items = model.historyTransfers.filter { $0.state == .failed }
        case .cancelled:
            items = model.historyTransfers.filter { $0.state == .cancelled }
        }
        return items.sorted { $0.updatedAt > $1.updatedAt }
    }
    private var groups: [(key: String, name: String, items: [TransferListItem])] {
        Dictionary(grouping: filtered, by: model.historyDeviceKey)
            .map { key, values in
                let items = values.sorted { $0.updatedAt > $1.updatedAt }
                return (key, items.first.map(model.historyDeviceName) ?? "未知设备", items)
            }
            .sorted { ($0.items.first?.updatedAt ?? .distantPast) > ($1.items.first?.updatedAt ?? .distantPast) }
    }
    private var currentIDs: Set<UUID> { Set(model.currentTransfers.map(\.id)) }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 0) {
                ForEach(HistoryStatusFilter.allCases) { item in
                    Button { filter = item } label: {
                        Text(item.rawValue)
                            .font(.system(size: 12, weight: filter == item ? .semibold : .medium))
                            .foregroundStyle(filter == item ? .white : Color.primary.opacity(0.72))
                            .frame(width: 98, height: 36)
                            .background(
                                filter == item ? MacAppTheme.selectedTabSurface : .clear,
                                in: RoundedRectangle(cornerRadius: 9)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(width: 98, height: 36)
                    .contentShape(Rectangle())
                    .accessibilityLabel("显示\(item.rawValue)的传输记录")
                }
            }
            .padding(3)
            .background(MacAppTheme.tabBarSurface, in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu {
                Button("清空全部历史", role: .destructive) { confirmingClearAll = true }
                    .disabled(model.historyTransfers.isEmpty)
            }
            if groups.isEmpty { Text("暂无历史记录").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 180).glassCard(radius: 16) }
            ForEach(groups, id: \.key) { group in
                VStack(spacing: 8) {
                    HStack {
                        Label(group.name, systemImage: "ipad").font(.system(size: 12, weight: .bold))
                        Spacer()
                        Text("\(group.items.count) 条记录").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button("清空此设备的历史", role: .destructive) {
                            pendingClearPeer = HistoryClearTarget(key: group.key, name: group.name)
                        }
                        .disabled(!model.historyTransfers.contains { model.historyDeviceKey($0) == group.key })
                        Button("清空全部历史", role: .destructive) { confirmingClearAll = true }
                            .disabled(model.historyTransfers.isEmpty)
                    }
                    ForEach(group.items) { item in
                        Group {
                            if currentIDs.contains(item.id) {
                                TaskControlRow(model: model, item: item)
                            } else {
                                FileRow(
                                    item: item,
                                    actions: .init(
                                        open: model.openTransferItem,
                                        reveal: model.revealTransferItem,
                                        delete: model.deleteHistoryItem,
                                        clearPeer: {
                                            pendingClearPeer = HistoryClearTarget(key: group.key, name: group.name)
                                        },
                                        clearAll: { confirmingClearAll = true },
                                        retry: model.retryHistoryItem
                                    )
                                )
                            }
                        }
                    }
                }
                .padding(14)
                .glassCard(radius: 17)
                .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                .contextMenu {
                    Button("清空此设备的历史", role: .destructive) {
                        pendingClearPeer = HistoryClearTarget(key: group.key, name: group.name)
                    }
                    .disabled(!model.historyTransfers.contains { model.historyDeviceKey($0) == group.key })
                    Button("清空全部历史", role: .destructive) { confirmingClearAll = true }
                        .disabled(model.historyTransfers.isEmpty)
                }
            }
        }
        .confirmationDialog("清空全部传输历史？", isPresented: $confirmingClearAll, titleVisibility: .visible) {
            Button("确认清空", role: .destructive) { model.clearHistory() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("历史记录不会自动恢复，已完成文件不会被删除。")
        }
        .confirmationDialog("清空该设备的传输历史？", isPresented: Binding(get: { pendingClearPeer != nil }, set: { if !$0 { pendingClearPeer = nil } }), titleVisibility: .visible) {
            Button("确认清空", role: .destructive) {
                if let peer = pendingClearPeer { model.clearHistory(deviceKey: peer.key) }
                pendingClearPeer = nil
            }
            Button("取消", role: .cancel) { pendingClearPeer = nil }
        } message: {
            Text("将删除 \(pendingClearPeer?.name ?? "该设备") 的全部传输记录，已完成文件不会被删除。")
        }
    }
}

private struct MacSettingsPage: View {
    let model: TransferViewModel
    @State private var confirmingClearStaging = false
    @State private var editingPorts = false
    @State private var draftUDPPort = ""
    @State private var draftTCPPort = ""
    @State private var draftCastPort = ""
    @State private var diagnosticButtonTitle = "复制诊断信息"
    @State private var directoryButtonTitle = "打开"
    var body: some View {
        VStack(spacing: 18) {
            PageHeader(title: "设置", subtitle: "所有配置只保存在本机，不上传云端。") { EmptyView() }
            VStack(spacing: 0) {
                settingsToggle("接收服务", detail: "允许已配对设备向本机发送文件", isOn: Binding(get: { model.receiverEnabled }, set: model.setReceiverEnabled))
                settingsToggle("自动发现", detail: "前台快速扫描，后台空闲时自动降频", isOn: Binding(get: { model.discoveryEnabled }, set: model.setDiscoveryEnabled))
                settingsToggle(
                    "已配对设备自动接收",
                    detail: "关闭后每个文件都需要确认",
                    isOn: Binding(get: { model.autoReceiveTrustedDevices }, set: model.setAutoReceiveTrustedDevices)
                )
                settingsToggle(
                    "后台传输保护",
                    detail: "仅在活动传输期间防止空闲休眠",
                    isOn: Binding(get: { model.backgroundTransferProtection }, set: model.setBackgroundTransferProtection)
                )
                settingsToggle(
                    "投屏接收服务",
                    detail: "允许已配对的 MatePad 将画面投到本机",
                    isOn: Binding(
                        get: { model.screenCastReceiverEnabled },
                        set: model.setScreenCastReceiverEnabled
                    )
                )
                settingsRow("诊断信息", detail: "不包含文件内容、完整路径或局域网地址") {
                    Button(diagnosticButtonTitle == "复制诊断信息" ? "复制" : diagnosticButtonTitle) {
                        copyDiagnosticInfo()
                    }
                    .help("复制版本、服务状态、端口、设备和任务信息")
                }
                settingsRow("下载目录", detail: "接收成功的文件保存在 \(model.receiveDirectory)") {
                    HStack(spacing: 8) {
                        Button(directoryButtonTitle) { openReceiveDirectory() }
                        Button("更改", action: model.chooseReceiveDirectory)
                    }
                }
                settingsRow("临时传输空间", detail: "应用私有 Staging · 未完成任务默认保留 7 天") { Button("清除", role: .destructive) { confirmingClearStaging = true } }
                settingsNavigationRow(
                    "网络服务",
                    detail: "发现 UDP \(model.localDiscoveryPort) · 传输 TCP \(model.localTCPPort) · 投屏 TCP \(model.localScreenCastPort)",
                    action: openPortEditor
                )
            }.padding(.horizontal, 18).glassCard(radius: 18)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("隐私与本地数据").font(.system(size: 13, weight: .semibold))
                    Text("无账号 · 无云端 · 配对关系仅保存在本机")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                if let privacyURL = URL(string: "https://hmt.tppc.top/privacy.html") {
                    Link("查看隐私政策", destination: privacyURL)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            .padding(18)
            .glassCard(radius: 18)
            Spacer()
        }
        .confirmationDialog("清除临时传输空间？", isPresented: $confirmingClearStaging, titleVisibility: .visible) {
            Button("确认清除", role: .destructive, action: model.clearTemporaryStorage)
            Button("取消", role: .cancel) {}
        } message: {
            Text("未完成任务的临时分片会被删除，已完成文件和历史记录不会受影响。")
        }
        .sheet(isPresented: $editingPorts) {
            MacPortEditorSheet(
                udpPort: $draftUDPPort,
                tcpPort: $draftTCPPort,
                castPort: $draftCastPort,
                cancel: { editingPorts = false },
                save: {
                    model.discoveryPortText = draftUDPPort
                    model.localTCPPortText = draftTCPPort
                    model.screenCastPortText = draftCastPort
                    model.applyNetworkPorts()
                    editingPorts = false
                }
            )
        }
    }

    private func openPortEditor() {
        draftUDPPort = model.discoveryPortText
        draftTCPPort = model.localTCPPortText
        draftCastPort = model.screenCastPortText
        editingPorts = true
    }

    private func copyDiagnosticInfo() {
        NSPasteboard.general.clearContents()
        let copied = NSPasteboard.general.setString(model.diagnosticReport, forType: .string)
        diagnosticButtonTitle = copied ? "已复制" : "复制失败"
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            diagnosticButtonTitle = "复制诊断信息"
        }
    }

    private func openReceiveDirectory() {
        directoryButtonTitle = model.openReceiveDirectory() ? "已打开" : "打开失败"
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            directoryButtonTitle = "打开"
        }
    }

    private func settingsToggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        settingsRow(title, detail: detail) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(title)
                .accessibilityHint(detail)
        }
    }
    private func settingsNavigationRow(_ title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 15)
            .overlay(alignment: .bottom) { Rectangle().fill(MacAppTheme.subtleBorder).frame(height: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
    private func settingsRow<Trailing: View>(_ title: String, detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack { VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 13, weight: .semibold)); Text(detail).font(.system(size: 10)).foregroundStyle(.secondary) }; Spacer(); trailing() }.padding(.vertical, 15).overlay(alignment: .bottom) { Rectangle().fill(MacAppTheme.subtleBorder).frame(height: 1) }
    }
}

private struct MacPortEditorSheet: View {
    @Binding var udpPort: String
    @Binding var tcpPort: String
    @Binding var castPort: String
    let cancel: () -> Void
    let save: () -> Void

    private var portsAreValid: Bool {
        guard let udp = UInt16(udpPort), udp > 0,
              let tcp = UInt16(tcpPort), tcp > 0,
              let cast = UInt16(castPort), cast > 0 else { return false }
        guard Set([udp, tcp, cast]).count == 3 else { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("修改网络端口").font(.system(size: 20, weight: .bold))
                Text("三个端口必须互不相同；保存后会重新启动发现、传输和投屏服务。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 14) {
                GridRow {
                    Text("UDP 发现端口").font(.system(size: 12, weight: .semibold))
                    TextField("51889", text: $udpPort).textFieldStyle(.roundedBorder).frame(width: 150)
                }
                GridRow {
                    Text("TCP 传输端口").font(.system(size: 12, weight: .semibold))
                    TextField("51888", text: $tcpPort).textFieldStyle(.roundedBorder).frame(width: 150)
                }
                GridRow {
                    Text("TCP 投屏端口").font(.system(size: 12, weight: .semibold))
                    TextField("51890", text: $castPort).textFieldStyle(.roundedBorder).frame(width: 150)
                }
            }
            HStack {
                Spacer()
                Button("取消", action: cancel)
                Button("保存并重启", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(!portsAreValid)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
