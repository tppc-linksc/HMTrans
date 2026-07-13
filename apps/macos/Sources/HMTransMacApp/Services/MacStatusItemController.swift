import AppKit
import SwiftUI

/// Native status-item controller. It owns the drag target and a lightweight
/// non-activating task panel, while the transfer engine remains in the model.
@MainActor
final class MacStatusItemController {
    static let shared = MacStatusItemController()

    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private weak var model: TransferViewModel?
    private var hoverTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?

    func install(model: TransferViewModel) {
        self.model = model
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: 34)
        guard let button = item.button else { return }
        button.image = nil
        let dropView = StatusBarDropView(frame: button.bounds)
        dropView.autoresizingMask = [.width, .height]
        dropView.onClick = { [weak self] in self?.togglePanel() }
        dropView.onHover = { [weak self] inside in self?.handleHover(inside) }
        dropView.onDragEntered = { [weak self] in self?.showPanel() }
        dropView.onDrop = { [weak self] urls in self?.handleDrop(urls) ?? false }
        button.addSubview(dropView)
        statusItem = item
    }

    private func handleDrop(_ urls: [URL]) -> Bool {
        guard let model, !urls.isEmpty else { return false }
        guard !model.activeTransferTargets.isEmpty else {
            showPanel()
            NSSound.beep()
            return false
        }
        model.sendDroppedFiles(urls)
        showPanel()
        return true
    }

    private func togglePanel() {
        if panel?.isVisible == true { panel?.orderOut(nil) } else { showPanel() }
    }

    private func handleHover(_ inside: Bool) {
        hoverTask?.cancel()
        closeTask?.cancel()
        if inside {
            hoverTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                self?.showPanel()
            }
        } else {
            schedulePanelClose()
        }
    }

    private func schedulePanelClose() {
        closeTask?.cancel()
        closeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }

    private func showPanel() {
        guard let model, let button = statusItem?.button else { return }
        let panel = panel ?? makePanel(model: model)
        self.panel = panel
        if let window = button.window {
            let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
            let visibleFrame = window.screen?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? anchor
            let proposedX = anchor.midX - panel.frame.width / 2
            let origin = NSPoint(
                x: min(max(proposedX, visibleFrame.minX + 8), visibleFrame.maxX - panel.frame.width - 8),
                y: max(anchor.minY - panel.frame.height - 8, visibleFrame.minY + 8)
            )
            panel.setFrameOrigin(origin)
        }
        panel.orderFrontRegardless()
    }

    private func makePanel(model: TransferViewModel) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 330, height: 360),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: StatusTransferPanel(
            model: model,
            showMainWindow: { _ = AppWindowController.showExistingMainWindow() },
            onHover: { [weak self] inside in
                if inside { self?.closeTask?.cancel() } else { self?.schedulePanelClose() }
            }
        ))
        return panel
    }
}

private final class StatusBarDropView: NSView {
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onDragEntered: (() -> Void)?
    var onDrop: (([URL]) -> Bool)?
    private var highlighted = false
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlighted = true
        needsDisplay = true
        onDragEntered?()
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlighted = false
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        needsDisplay = true
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        return onDrop?(urls) ?? false
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = highlighted ? NSColor.controlAccentColor.withAlphaComponent(0.24) : .clear
        background.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8).fill()
        StatusItemIconFactory.image(highlighted: highlighted)
            .draw(in: NSRect(x: bounds.midX - 10, y: bounds.midY - 9, width: 20, height: 18))
    }
}

private enum StatusItemIconFactory {
    static func image(highlighted: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            let color = highlighted ? NSColor.controlAccentColor : NSColor.labelColor
            color.setStroke()
            let laptop = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 6, width: 8, height: 7), xRadius: 1.2, yRadius: 1.2)
            laptop.lineWidth = 1.5; laptop.stroke()
            let base = NSBezierPath(); base.move(to: NSPoint(x: 0.7, y: 4.5)); base.line(to: NSPoint(x: 10.3, y: 4.5)); base.lineWidth = 1.5; base.stroke()
            let tablet = NSBezierPath(roundedRect: NSRect(x: 13, y: 3, width: 5.5, height: 11), xRadius: 1.4, yRadius: 1.4)
            tablet.lineWidth = 1.5; tablet.stroke()
            let channel = NSBezierPath(); channel.move(to: NSPoint(x: 10.4, y: 10.2)); channel.line(to: NSPoint(x: 13, y: 10.2)); channel.move(to: NSPoint(x: 12, y: 11.2)); channel.line(to: NSPoint(x: 13, y: 10.2)); channel.line(to: NSPoint(x: 12, y: 9.2)); channel.lineWidth = 1.2; channel.stroke()
            channel.move(to: NSPoint(x: 13, y: 7)); channel.line(to: NSPoint(x: 10.4, y: 7)); channel.move(to: NSPoint(x: 11.4, y: 8)); channel.line(to: NSPoint(x: 10.4, y: 7)); channel.line(to: NSPoint(x: 11.4, y: 6)); channel.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "HM互传"
        return image
    }
}

private struct StatusTransferPanel: View {
    let model: TransferViewModel
    let showMainWindow: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("HM互传").font(.system(size: 15, weight: .bold))
                Spacer()
                Button("打开任务中心", action: showMainWindow).buttonStyle(.borderless)
            }

            Text("发送目标").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if model.connectedDevices.isEmpty {
                Text("暂无已配对在线设备").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ForEach(model.connectedDevices, id: \.deviceId) { device in
                    Button { model.toggleTransferTarget(device) } label: {
                        HStack {
                            Image(systemName: model.selectedTargetDeviceIDs.contains(device.deviceId)
                                  ? "checkmark.circle.fill" : "circle")
                            Text(device.deviceName).lineLimit(1)
                            Spacer()
                            Circle().fill(.green).frame(width: 7, height: 7)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()
            Text("当前任务").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if model.currentTransfers.isEmpty {
                Text("把文件拖到状态栏图标即可发送").font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 78)
            } else {
                ForEach(model.currentTransfers.prefix(3)) { item in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.fileName).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                            ProgressView(value: item.progress)
                        }
                        Button { model.togglePause(item) } label: {
                            Image(systemName: item.state == .paused ? "play.fill" : "pause.fill")
                        }.buttonStyle(.borderless)
                        Button { model.cancel(item) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            Spacer(minLength: 0)
            Text("可拖入文件或文件夹；移出图标不会创建任务")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 330, height: 360)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.34)))
        .onHover(perform: onHover)
    }
}
