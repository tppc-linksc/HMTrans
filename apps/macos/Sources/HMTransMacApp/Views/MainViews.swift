import AppKit
import SwiftUI

/// Secondary Settings scene retained for the standard macOS Settings command.
struct SettingsView: View {
    let model: TransferViewModel

    var body: some View {
        Form {
            Section("接收") {
                LabeledContent("保存位置", value: model.receiveDirectory)
                Button("选择接收目录") { model.chooseReceiveDirectory() }
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
    var body: some View { V02RootView(model: model) }
}

/// One history row owns its complete context menu so right-clicking never
/// requires finding a narrow gap between nested cards.
struct FileRow: View {
    struct Actions {
        let open: (TransferListItem) -> Void
        let reveal: (TransferListItem) -> Void
        let delete: ((TransferListItem) -> Void)?
        let clearPeer: (() -> Void)?
        let clearAll: (() -> Void)?
        let retry: ((TransferListItem) -> Void)?
    }

    let item: TransferListItem
    let actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.direction == .sending ? "arrow.up.doc.fill" : "arrow.down.doc.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(MacAppTheme.accent)
                .frame(width: 42, height: 42)
                .background(MacAppTheme.blueSurface, in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.fileName).font(.system(size: 13, weight: .bold)).lineLimit(1).help(item.fileName)
                    Spacer()
                    Text(item.state.rawValue).font(.system(size: 12, weight: .semibold)).foregroundStyle(stateColor)
                }
                HStack {
                    Text("\(item.direction.rawValue) · \(item.peerName)")
                    Spacer()
                    Text(item.timeText)
                }
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.primary.opacity(0.68))
                ProgressView(value: item.progress).tint(MacAppTheme.accent)
                    .opacity(item.state == .active ? 0.82 : 0.28)
                Text(item.detail).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.68)).lineLimit(1).help(item.detail)
            }
        }
        .padding(10)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .background(MacAppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(MacAppTheme.subtleBorder))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.fileName)，\(item.direction.rawValue)，\(item.peerName)，\(item.state.rawValue)")
        .accessibilityValue(item.detail)
        .contextMenu { contextMenu }
    }

    @ViewBuilder private var contextMenu: some View {
        if item.direction == .sending && (item.state == .failed || item.state == .cancelled),
           let retry = actions.retry {
            Button("重试此任务") { retry(item) }
        }
        if item.state == .done {
            Button("打开") { actions.open(item) }
            Button("在 Finder 中显示") { actions.reveal(item) }
        }
        if actions.delete != nil || actions.clearPeer != nil || actions.clearAll != nil { Divider() }
        if let delete = actions.delete { Button("删除此记录", role: .destructive) { delete(item) } }
        if let clearPeer = actions.clearPeer { Button("清空此设备的记录", role: .destructive, action: clearPeer) }
        if let clearAll = actions.clearAll { Button("清空全部记录", role: .destructive, action: clearAll) }
    }

    private var stateColor: Color {
        switch item.state {
        case .queued, .preparing, .active, .verifying: MacAppTheme.accent
        case .paused, .waiting: .orange
        case .done: .green
        case .failed: .red
        case .cancelled: .secondary
        }
    }
}

extension View {
    func glassCard(radius: CGFloat) -> some View {
        background(MacAppTheme.cardSurface, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(MacAppTheme.border))
            .shadow(color: MacAppTheme.shadow, radius: 6, x: 0, y: 2)
    }
}
