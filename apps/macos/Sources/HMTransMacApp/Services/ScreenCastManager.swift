import Foundation
import HMTransCore
import Observation

enum ScreenCastReceivingState: String, Sendable {
    case stopped
    case listening
    case connecting
    case casting
    case failed
}

/// 管理投屏监听、解码状态和窗口生命周期；文件传输 ViewModel 只负责启动或重启服务。
@MainActor
@Observable
final class ScreenCastManager {
    private(set) var state: ScreenCastReceivingState = .stopped
    private(set) var detail = "投屏服务未启动"
    private(set) var deviceName = "MatePad"
    private(set) var sourceWidth = 16
    private(set) var sourceHeight = 10
    private(set) var frameRate = 0
    private(set) var bitrate = 0
    private(set) var listeningPort: UInt16 = defaultScreenCastPort

    let renderer = ScreenCastVideoRenderer()
    private let receiver = ScreenCastReceiverService()
    private var statisticStartedAt = Date()
    private var statisticFrames = 0
    private var statisticBytes = 0

    var isCasting: Bool { state == .connecting || state == .casting }
    var sourceAspectRatio: CGFloat { CGFloat(max(1, sourceWidth)) / CGFloat(max(1, sourceHeight)) }

    func start(port: UInt16) {
        listeningPort = port
        do {
            try receiver.start(port: port, callbacks: makeCallbacks())
            state = .listening
            detail = "等待已配对的 MatePad 发起投屏"
        } catch {
            state = .failed
            detail = "投屏服务启动失败：\(error.localizedDescription)"
        }
    }

    func restart(port: UInt16) {
        receiver.stop()
        renderer.reset()
        state = .stopped
        start(port: port)
    }

    func stopService() {
        receiver.stop()
        renderer.reset()
        state = .stopped
        detail = "投屏服务已停止"
        ScreenCastWindowRegistry.close()
    }

    func stopCasting() {
        receiver.stopActiveStream()
        renderer.reset()
        state = .listening
        detail = "等待已配对的 MatePad 发起投屏"
        ScreenCastWindowRegistry.close()
    }

    func showPlayer(pictureInPicture: Bool = false) {
        guard isCasting else { return }
        ScreenCastWindowRegistry.show(manager: self, pictureInPicture: pictureInPicture)
    }

    private func makeCallbacks() -> ScreenCastReceiverService.Callbacks {
        ScreenCastReceiverService.Callbacks(
            onListening: { [weak self] port in
                Task { @MainActor in
                    guard let self, !self.isCasting else { return }
                    self.listeningPort = port
                    self.state = .listening
                    self.detail = "等待已配对的 MatePad 发起投屏"
                }
            },
            onConnected: { [weak self] hello in
                Task { @MainActor in
                    guard let self else { return }
                    self.renderer.reset()
                    self.deviceName = hello.deviceName
                    self.sourceWidth = max(1, hello.width)
                    self.sourceHeight = max(1, hello.height)
                    self.state = .connecting
                    self.detail = "正在接收 \(hello.deviceName) 的画面"
                    self.resetStatistics()
                    ScreenCastWindowRegistry.show(manager: self, pictureInPicture: false)
                    ScreenCastWindowRegistry.updateAspectRatio(self.sourceAspectRatio)
                }
            },
            onVideoConfig: { [weak self] config in
                Task { @MainActor in
                    guard let self else { return }
                    self.sourceWidth = max(1, config.width)
                    self.sourceHeight = max(1, config.height)
                    ScreenCastWindowRegistry.updateAspectRatio(self.sourceAspectRatio)
                }
            },
            onVideoFrame: { [weak self] data, ptsUs, keyFrame, codecConfig in
                Task { @MainActor in
                    guard let self else { return }
                    do {
                        try self.renderer.enqueue(
                            annexB: data,
                            presentationTimeUs: ptsUs,
                            isKeyFrame: keyFrame,
                            isCodecConfig: codecConfig
                        )
                        let dimensions = self.renderer.videoDimensions
                        if dimensions.width > 0, dimensions.height > 0,
                           self.sourceWidth != Int(dimensions.width) || self.sourceHeight != Int(dimensions.height) {
                            self.sourceWidth = Int(dimensions.width)
                            self.sourceHeight = Int(dimensions.height)
                            ScreenCastWindowRegistry.updateAspectRatio(self.sourceAspectRatio)
                        }
                        self.state = .casting
                        self.detail = "正在投屏"
                        self.updateStatistics(bytes: data.count)
                    } catch {
                        self.state = .failed
                        self.detail = error.localizedDescription
                        self.receiver.stopActiveStream(reason: "Mac 解码失败")
                    }
                }
            },
            onDisconnected: { [weak self] reason in
                Task { @MainActor in
                    guard let self else { return }
                    self.renderer.reset()
                    self.state = .listening
                    self.detail = reason
                    self.frameRate = 0
                    self.bitrate = 0
                    ScreenCastWindowRegistry.close()
                }
            },
            onFailure: { [weak self] reason in
                Task { @MainActor in
                    self?.state = .failed
                    self?.detail = reason
                }
            }
        )
    }

    private func resetStatistics() {
        statisticStartedAt = Date()
        statisticFrames = 0
        statisticBytes = 0
        frameRate = 0
        bitrate = 0
    }

    private func updateStatistics(bytes: Int) {
        statisticFrames += 1
        statisticBytes += bytes
        let elapsed = Date().timeIntervalSince(statisticStartedAt)
        guard elapsed >= 1 else { return }
        frameRate = Int((Double(statisticFrames) / elapsed).rounded())
        bitrate = Int((Double(statisticBytes * 8) / elapsed).rounded())
        statisticStartedAt = Date()
        statisticFrames = 0
        statisticBytes = 0
    }
}
