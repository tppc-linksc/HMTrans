import AppKit
import AVFoundation
import SwiftUI

struct ScreenCastPlayerView: View {
    let session: ScreenCastSessionModel
    let isPictureInPicture: Bool
    let togglePictureInPicture: () -> Void
    let toggleFullScreen: () -> Void
    let stop: () -> Void

    var body: some View {
        ZStack {
            Color.black
            ScreenCastLayerView(displayLayer: session.renderer.displayLayer)
            VStack {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.deviceName)
                            .font(.system(size: isPictureInPicture ? 11 : 13, weight: .semibold))
                        if !isPictureInPicture {
                            Text("\(session.sourceWidth) × \(session.sourceHeight) · \(session.frameRate) fps · \(formatBitrate(session.bitrate))")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(action: togglePictureInPicture) {
                        Image(systemName: isPictureInPicture ? "rectangle.inset.filled" : "pip")
                    }
                    .help(isPictureInPicture ? "返回普通窗口" : "画中画")
                    Button(action: toggleFullScreen) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .help("全屏")
                    Button(role: .destructive, action: stop) { Image(systemName: "stop.fill") }
                        .help("只停止这台 Pad 的投屏")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 11))
                .padding(10)
                Spacer()
            }
        }
        .ignoresSafeArea()
    }

    private func formatBitrate(_ value: Int) -> String {
        guard value > 0 else { return "0 Mbps" }
        return String(format: "%.1f Mbps", Double(value) / 1_000_000)
    }
}

private struct ScreenCastLayerView: NSViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> ScreenCastLayerHostView {
        ScreenCastLayerHostView(displayLayer: displayLayer)
    }

    func updateNSView(_ nsView: ScreenCastLayerHostView, context: Context) {
        nsView.install(displayLayer)
    }
}

private final class ScreenCastLayerHostView: NSView {
    private weak var displayLayer: AVSampleBufferDisplayLayer?

    init(displayLayer: AVSampleBufferDisplayLayer) {
        super.init(frame: .zero)
        wantsLayer = true
        install(displayLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func install(_ layer: AVSampleBufferDisplayLayer) {
        guard displayLayer !== layer else { return }
        displayLayer?.removeFromSuperlayer()
        displayLayer = layer
        self.layer?.addSublayer(layer)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        displayLayer?.frame = bounds
    }
}

@MainActor
enum ScreenCastWindowRegistry {
    private static var controllers: [String: ScreenCastWindowController] = [:]

    static func show(
        session: ScreenCastSessionModel,
        pictureInPicture: Bool,
        stop: @escaping () -> Void
    ) {
        if controllers[session.id] == nil {
            controllers[session.id] = ScreenCastWindowController(session: session, stop: stop)
        }
        controllers[session.id]?.show(pictureInPicture: pictureInPicture)
    }

    static func updateAspectRatio(sessionID: String, ratio: CGFloat) {
        controllers[sessionID]?.updateAspectRatio(ratio)
    }

    static func close(sessionID: String) {
        controllers.removeValue(forKey: sessionID)?.closeWithoutStopping()
    }

    static func closeAll() {
        controllers.values.forEach { $0.closeWithoutStopping() }
        controllers.removeAll()
    }
}

@MainActor
private final class ScreenCastWindowController: NSObject, NSWindowDelegate {
    private let session: ScreenCastSessionModel
    private let stop: () -> Void
    private let window: NSWindow
    private var pictureInPicture = false
    private var snapWorkItem: DispatchWorkItem?

    private var pictureInPictureFrameKey: String {
        "screenCastPictureInPictureFrame.\(session.deviceID)"
    }

    init(session: ScreenCastSessionModel, stop: @escaping () -> Void) {
        self.session = session
        self.stop = stop
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.delegate = self
        window.title = "HM互传投屏 · \(session.deviceName)"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 240)
        updateContent()
        updateAspectRatio(session.sourceAspectRatio)
    }

    func show(pictureInPicture: Bool) {
        setPictureInPicture(pictureInPicture)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateAspectRatio(_ ratio: CGFloat) {
        guard ratio.isFinite, ratio > 0 else { return }
        window.contentAspectRatio = NSSize(width: ratio, height: 1)
    }

    func closeWithoutStopping() {
        snapWorkItem?.cancel()
        window.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        stop()
        return false
    }

    func windowDidMove(_ notification: Notification) {
        guard pictureInPicture else { return }
        snapWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.snapToNearestCorner() }
        snapWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
    }

    private func updateContent() {
        window.contentViewController = NSHostingController(rootView: ScreenCastPlayerView(
            session: session,
            isPictureInPicture: pictureInPicture,
            togglePictureInPicture: { [weak self] in
                guard let self else { return }
                self.setPictureInPicture(!self.pictureInPicture)
            },
            toggleFullScreen: { [weak self] in self?.toggleFullScreen() },
            stop: stop
        ))
    }

    private func setPictureInPicture(_ enabled: Bool) {
        guard pictureInPicture != enabled || window.contentViewController == nil else { return }
        pictureInPicture = enabled
        if enabled {
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            if let saved = UserDefaults.standard.string(forKey: pictureInPictureFrameKey) {
                window.setFrame(NSRectFromString(saved), display: true)
            } else {
                let width: CGFloat = 420
                window.setContentSize(NSSize(width: width, height: width / session.sourceAspectRatio))
                snapToNearestCorner(force: true)
            }
        } else {
            UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: pictureInPictureFrameKey)
            window.level = .normal
            window.collectionBehavior = [.managed, .fullScreenPrimary]
            window.setContentSize(NSSize(width: 960, height: 960 / session.sourceAspectRatio))
            window.center()
        }
        updateContent()
    }

    private func toggleFullScreen() {
        if pictureInPicture { setPictureInPicture(false) }
        window.toggleFullScreen(nil)
    }

    private func snapToNearestCorner(force: Bool = false) {
        guard pictureInPicture, let screen = window.screen ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 18
        let corners = [
            NSPoint(x: visible.minX + margin, y: visible.minY + margin),
            NSPoint(x: visible.maxX - window.frame.width - margin, y: visible.minY + margin),
            NSPoint(x: visible.minX + margin, y: visible.maxY - window.frame.height - margin),
            NSPoint(x: visible.maxX - window.frame.width - margin, y: visible.maxY - window.frame.height - margin),
        ]
        let origin = window.frame.origin
        guard let nearest = corners.min(by: { distance($0, origin) < distance($1, origin) }) else { return }
        if force || distance(nearest, origin) < 110 {
            window.setFrameOrigin(nearest)
            UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: pictureInPictureFrameKey)
        }
    }

    private func distance(_ lhs: NSPoint, _ rhs: NSPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }
}
