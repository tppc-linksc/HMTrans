import AppKit
import HMTransCore
import SwiftUI

struct SettingsView: View {
    let model: TransferViewModel

    var body: some View {
        Form {
            Section("接收") {
                LabeledContent("保存位置", value: model.receiveDirectory)
                Button("选择接收目录") {
                    model.chooseReceiveDirectory()
                }
            }
            Section("网络") {
                LabeledContent("接收端口", value: String(model.port))
                LabeledContent("设备名称", value: model.deviceName)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 520)
    }
}

struct ContentView: View {
    let model: TransferViewModel

    var body: some View {
        ZStack {
            GlassBackground()
            VStack(spacing: 14) {
                AppHeaderView(model: model)
                DropTransferView(model: model)
                NearbyDevicesStrip(model: model)
                FilesWorkspaceView(model: model)
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .ignoresSafeArea(.container, edges: .top)
    }
}

struct GlassBackground: View {
    var body: some View {
        MacAppTheme.windowBackground
            .ignoresSafeArea()
    }
}

struct AppHeaderView: View {
    let model: TransferViewModel

    var body: some View {
        HStack(alignment: .center) {
            Spacer()

            if let device = model.selectedNearbyDevice {
                HStack(spacing: 8) {
                    Text(device.deviceName)
                        .font(.system(size: 12, weight: .semibold))
                    Text(device.ip)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("connected")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.green)
                }
            } else {
                Text("unconnected")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 22)
        .padding(.leading, 24)
        .padding(.trailing, 24)
    }
}

struct DropTransferView: View {
    let model: TransferViewModel

    var body: some View {
        Button {
            model.chooseFile()
        } label: {
            VStack(spacing: 10) {
                Image(systemName: model.isDropTargeted ? "arrow.down.doc.fill" : "plus")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(MacAppTheme.accent)
                    .frame(width: 66, height: 66)
                    .background(MacAppTheme.elevatedSurface, in: Circle())
                    .shadow(color: MacAppTheme.softShadow, radius: 16, y: 8)
                Text(model.isDropTargeted ? "松开开始发送" : "拖入文件，或点击选择")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.primary)
                Text(model.isConnectedToDiscoveredDevice ? "支持任意文件类型，原文件局域网直传" : "等待自动发现设备后即可发送")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
            .background(MacAppTheme.softSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(style: StrokeStyle(lineWidth: 1.4, dash: [8, 6]))
                    .foregroundStyle(model.isDropTargeted ? MacAppTheme.activeBorder : MacAppTheme.border)
                    .padding(18)
            )
        }
        .buttonStyle(.plain)
        .background(MacAppTheme.cardSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(MacAppTheme.border, lineWidth: 1)
        )
        .shadow(color: MacAppTheme.shadow, radius: 18, x: 0, y: 10)
        .layoutPriority(2)
        .dropDestination(for: URL.self) { urls, _ in
            model.sendDroppedFiles(urls)
            return true
        } isTargeted: { targeted in
            model.isDropTargeted = targeted
        }
    }
}

struct NearbyDevicesStrip: View {
    let model: TransferViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("附近设备")
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                Text(model.nearbyDevices.isEmpty ? "搜索中" : "\(model.nearbyDevices.count) 台")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if model.nearbyDevices.isEmpty {
                HStack {
                    Spacer()
                    if model.host.isEmpty {
                        EmptyDeviceCard()
                    } else {
                        SavedTargetCard(host: model.host, port: model.port) {
                            model.clearSavedTarget()
                        }
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .frame(height: 66)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(model.nearbyDevices) { device in
                            DeviceCard(device: device, selected: model.host == device.ip) {
                                model.selectDevice(device)
                            } onDelete: {
                                model.forgetDevice(device)
                            }
                        }
                    }
                }
                .frame(height: 66)
            }
        }
        .padding(12)
        .glassCard(radius: 18)
        .frame(height: 116)
    }
}

struct EmptyDeviceCard: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(MacAppTheme.accent)
                .frame(width: 34, height: 34)
                .background(MacAppTheme.blueSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("正在搜索同一 Wi-Fi 设备")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("也可保留上次连接地址")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.primary.opacity(0.68))
            }
        }
        .frame(width: 220, height: 58, alignment: .leading)
        .padding(.horizontal, 12)
        .background(MacAppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(MacAppTheme.subtleBorder, lineWidth: 1)
        )
    }
}

struct SavedTargetCard: View {
    let host: String
    let port: UInt16
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(MacAppTheme.accent)
                .frame(width: 34, height: 34)
                .background(MacAppTheme.blueSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("已保存目标")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("\(host):\(String(port))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .lineLimit(1)
                    .monospacedDigit()
            }
            Spacer()
            Text("等待发现")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MacAppTheme.accent)
                .lineLimit(1)
        }
        .frame(width: 250, height: 58, alignment: .leading)
        .padding(.horizontal, 12)
        .background(MacAppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(MacAppTheme.subtleBorder, lineWidth: 1)
        )
        .contextMenu {
            Button("删除保存目标") {
                onDelete()
            }
        }
    }
}

struct DeviceCard: View {
    let device: DeviceInfo
    let selected: Bool
    let action: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let icon = AppIconLoader.deviceIconImage(platform: device.platform) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 42, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    Image(systemName: device.platform == "HarmonyOS" ? "ipad" : "macbook")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(MacAppTheme.accent)
                        .frame(width: 42, height: 42)
                        .background(MacAppTheme.blueSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.deviceName)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.primary)
                        .help(device.deviceName)
                    Text(device.systemVersion.map { "\(device.platform) · \($0)" } ?? device.platform)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.72))
                        .lineLimit(1)
                        .help(device.systemVersion.map { "\(device.platform) · \($0)" } ?? device.platform)
                    Text(device.ip)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.72))
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "paperplane")
                    .foregroundStyle(selected ? .green : MacAppTheme.accent)
            }
            .frame(width: 174, height: 58)
            .padding(.horizontal, 10)
            .background(selected ? MacAppTheme.blueSurface : MacAppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(selected ? MacAppTheme.activeBorder : MacAppTheme.subtleBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("删除此设备") {
                onDelete()
            }
        }
    }
}

struct FilesWorkspaceView: View {
    let model: TransferViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TransferPane(
                title: "当前传输",
                systemImage: "arrow.up.arrow.down",
                count: model.currentTransfers.count,
                items: model.currentTransfers,
                emptyTitle: "暂无正在传输的文件",
                emptySubtitle: model.receiverRunning ? "拖入文件即可发送，接收服务已常驻开启" : "接收服务未开启",
                openAction: model.openTransferItem,
                revealAction: model.revealTransferItem
            )
            TransferPane(
                title: "历史记录",
                systemImage: "clock.arrow.circlepath",
                count: model.historyTransfers.count,
                items: model.historyTransfers,
                emptyTitle: "暂无历史记录",
                emptySubtitle: "完成或失败的文件会显示在这里",
                openAction: model.openTransferItem,
                revealAction: model.revealTransferItem
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .layoutPriority(3)
    }
}

struct TransferPane: View {
    let title: String
    let systemImage: String
    let count: Int
    let items: [TransferListItem]
    let emptyTitle: String
    let emptySubtitle: String
    let openAction: (TransferListItem) -> Void
    let revealAction: (TransferListItem) -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(MacAppTheme.accent)
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                Text("\(count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(MacAppTheme.elevatedSurface, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(MacAppTheme.subtleBorder, lineWidth: 1)
                    )
            }
            FileList(items: items, emptyTitle: emptyTitle, emptySubtitle: emptySubtitle, openAction: openAction, revealAction: revealAction)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassCard(radius: 20)
    }
}

struct FileList: View {
    let items: [TransferListItem]
    let emptyTitle: String
    let emptySubtitle: String
    let openAction: (TransferListItem) -> Void
    let revealAction: (TransferListItem) -> Void

    var body: some View {
        if items.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "tray")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(MacAppTheme.accentMuted)
                    .frame(width: 50, height: 50)
                    .background(MacAppTheme.blueSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(emptyTitle)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.primary)
                Text(emptySubtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.68))
                    .multilineTextAlignment(.center)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .frame(minHeight: 220)
            .background(MacAppTheme.softSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(MacAppTheme.subtleBorder, lineWidth: 1)
            )
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(items) { item in
                        FileRow(item: item, openAction: openAction, revealAction: revealAction)
                    }
                }
            }
        }
    }
}

struct FileRow: View {
    let item: TransferListItem
    let openAction: (TransferListItem) -> Void
    let revealAction: (TransferListItem) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(MacAppTheme.accent)
                .frame(width: 42, height: 42)
                .background(MacAppTheme.blueSurface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.fileName)
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                        .help(item.fileName)
                    Spacer()
                    Text(item.state.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(stateColor)
                }
                HStack {
                    Text("\(item.direction.rawValue) · \(item.peerName)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.68))
                        .help("\(item.direction.rawValue) · \(item.peerName)")
                    Spacer()
                    Text(item.timeText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.68))
                }
                ProgressView(value: item.progress)
                    .tint(MacAppTheme.accent)
                    .opacity(item.state == .active ? 0.82 : 0.28)
                Text(item.detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.68))
                    .lineLimit(1)
                    .help(item.detail)
            }
        }
        .padding(10)
        .background(MacAppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(MacAppTheme.subtleBorder, lineWidth: 1)
        )
        .contextMenu {
            if item.state == .done, item.localURL != nil {
                Button("打开") {
                    openAction(item)
                }
                Button("在 Finder 中显示") {
                    revealAction(item)
                }
            }
        }
    }

    private var iconName: String {
        item.direction == .sending ? "arrow.up.doc.fill" : "arrow.down.doc.fill"
    }

    private var stateColor: Color {
        switch item.state {
        case .active: return MacAppTheme.accent
        case .done: return .green
        case .failed: return .red
        }
    }
}

extension View {
    func glassCard(radius: CGFloat) -> some View {
        self
            .background(MacAppTheme.cardSurface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(MacAppTheme.border, lineWidth: 1)
            )
            .shadow(color: MacAppTheme.shadow, radius: 18, x: 0, y: 10)
    }
}
