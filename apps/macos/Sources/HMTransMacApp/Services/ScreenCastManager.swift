import Foundation
import HMTransCore
import Observation
import OSLog

private let screenCastManagerLogger = Logger(subsystem: "com.linksc.hmtrans.mac", category: "ScreenCast")

enum ScreenCastReceivingState: String, Sendable {
    case stopped
    case listening
    case connecting
    case casting
    case failed
}

@MainActor
@Observable
final class ScreenCastSessionModel: Identifiable {
    let id: String
    let deviceID: String
    nonisolated let renderer: ScreenCastVideoRenderer

    private(set) var state: ScreenCastReceivingState = .connecting
    private(set) var detail = "正在建立画面"
    private(set) var deviceName: String
    private(set) var sourceWidth: Int
    private(set) var sourceHeight: Int
    private(set) var frameRate = 0
    private(set) var bitrate = 0

    private var statisticStartedAt = Date()
    private var statisticFrames = 0
    private var statisticBytes = 0

    init(id: String, hello: ScreenCastHello) {
        renderer = ScreenCastVideoRenderer()
        self.id = id
        deviceID = hello.deviceId
        deviceName = hello.deviceName
        sourceWidth = max(1, hello.width)
        sourceHeight = max(1, hello.height)
    }

    var sourceAspectRatio: CGFloat {
        CGFloat(max(1, sourceWidth)) / CGFloat(max(1, sourceHeight))
    }

    func apply(_ config: ScreenCastVideoConfig) {
        sourceWidth = max(1, config.width)
        sourceHeight = max(1, config.height)
    }

    nonisolated func decode(
        data: Data,
        ptsUs: UInt64,
        keyFrame: Bool,
        codecConfig: Bool,
        completion: @escaping @Sendable (Result<ScreenCastDecodeOutcome, Error>) -> Void
    ) {
        renderer.enqueueAsync(
            annexB: data,
            presentationTimeUs: ptsUs,
            isKeyFrame: keyFrame,
            isCodecConfig: codecConfig,
            completion: completion
        )
    }

    func recordDisplayedFrame(_ outcome: ScreenCastDecodeOutcome, bytes: Int) {
        guard outcome.displayed else { return }
        if outcome.width > 0, outcome.height > 0 {
            sourceWidth = outcome.width
            sourceHeight = outcome.height
        }
        state = .casting
        detail = "正在投屏"
        updateStatistics(bytes: bytes)
    }

    func fail(_ reason: String) {
        state = .failed
        detail = reason
    }

    func reset() {
        renderer.reset()
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

/// 管理监听器和多个彼此隔离的投屏会话。每个会话拥有自己的解码器、统计与窗口。
@MainActor
@Observable
final class ScreenCastManager {
    static let maximumConcurrentStreams = ScreenCastReceiverService.maximumConcurrentStreams

    private(set) var state: ScreenCastReceivingState = .stopped
    private(set) var detail = "投屏服务未启动"
    private(set) var listeningPort: UInt16 = defaultScreenCastPort
    private(set) var sessions: [ScreenCastSessionModel] = []
    private(set) var lastNetworkTestResult: ScreenCastNetworkTestResult?

    private let receiver = ScreenCastReceiverService()

    var isCasting: Bool { !sessions.isEmpty }
    var canAcceptNewSession: Bool { sessions.count < Self.maximumConcurrentStreams }
    var activeSessionCount: Int { sessions.count }

    func session(for id: String) -> ScreenCastSessionModel? {
        sessions.first { $0.id == id }
    }

    func isCasting(deviceID: String) -> Bool {
        sessions.contains { $0.deviceID == deviceID }
    }

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
        clearAllSessions()
        state = .stopped
        start(port: port)
    }

    func stopService() {
        receiver.stop()
        clearAllSessions()
        state = .stopped
        detail = "投屏服务已停止"
    }

    func stopCasting(sessionID: String) {
        receiver.stopStream(sessionID: sessionID)
    }

    func stopAllCasting() {
        receiver.stopAllStreams()
    }

    func showPlayer(sessionID: String, pictureInPicture: Bool = false) {
        guard let session = session(for: sessionID) else { return }
        ScreenCastWindowRegistry.show(
            session: session,
            pictureInPicture: pictureInPicture,
            stop: { [weak self] in self?.stopCasting(sessionID: sessionID) }
        )
    }

    private func makeCallbacks() -> ScreenCastReceiverService.Callbacks {
        ScreenCastReceiverService.Callbacks(
            onListening: { [weak self] port in
                Task { @MainActor in
                    guard let self else { return }
                    self.listeningPort = port
                    if self.sessions.isEmpty {
                        self.state = .listening
                        self.detail = "等待已配对的 MatePad 发起投屏"
                    }
                }
            },
            onConnected: { [weak self] sessionID, hello in
                Task { @MainActor in
                    guard let self, self.session(for: sessionID) == nil else { return }
                    let session = ScreenCastSessionModel(id: sessionID, hello: hello)
                    self.sessions.append(session)
                    self.state = .connecting
                    self.updateOverallDetail()
                    ScreenCastWindowRegistry.show(
                        session: session,
                        pictureInPicture: false,
                        stop: { [weak self] in self?.stopCasting(sessionID: sessionID) }
                    )
                    ScreenCastWindowRegistry.updateAspectRatio(
                        sessionID: sessionID,
                        ratio: session.sourceAspectRatio
                    )
                }
            },
            onVideoConfig: { [weak self] sessionID, config in
                Task { @MainActor in
                    guard let session = self?.session(for: sessionID) else { return }
                    session.apply(config)
                    ScreenCastWindowRegistry.updateAspectRatio(
                        sessionID: sessionID,
                        ratio: session.sourceAspectRatio
                    )
                }
            },
            onVideoFrame: { [weak self] sessionID, data, ptsUs, keyFrame, codecConfig in
                Task { @MainActor in
                    guard let self, let session = self.session(for: sessionID) else { return }
                    session.decode(
                        data: data,
                        ptsUs: ptsUs,
                        keyFrame: keyFrame,
                        codecConfig: codecConfig
                    ) { [weak self] result in
                        Task { @MainActor in
                            guard let self, let current = self.session(for: sessionID), current === session else {
                                return
                            }
                            switch result {
                            case let .success(outcome):
                                let previousRatio = session.sourceAspectRatio
                                session.recordDisplayedFrame(outcome, bytes: data.count)
                                guard outcome.displayed else { return }
                                if abs(previousRatio - session.sourceAspectRatio) > 0.001 {
                                    ScreenCastWindowRegistry.updateAspectRatio(
                                        sessionID: sessionID,
                                        ratio: session.sourceAspectRatio
                                    )
                                }
                                self.state = .casting
                                self.updateOverallDetail()
                            case let .failure(error):
                                screenCastManagerLogger.error(
                                    "解码投屏帧失败 session=\(sessionID, privacy: .public)：\(error.localizedDescription, privacy: .public)"
                                )
                                session.fail(error.localizedDescription)
                                self.receiver.stopStream(sessionID: sessionID, reason: "Mac 解码失败")
                            }
                        }
                    }
                }
            },
            onDisconnected: { [weak self] sessionID, reason in
                Task { @MainActor in
                    guard let self, let session = self.session(for: sessionID) else { return }
                    session.reset()
                    self.sessions.removeAll { $0.id == sessionID }
                    ScreenCastWindowRegistry.close(sessionID: sessionID)
                    self.state = self.sessions.isEmpty ? .listening :
                        (self.sessions.contains { $0.state == .casting } ? .casting : .connecting)
                    self.detail = self.sessions.isEmpty ? reason : "\(reason)；其余 \(self.sessions.count) 路继续投屏"
                }
            },
            onNetworkTestCompleted: { [weak self] result in
                Task { @MainActor in
                    self?.lastNetworkTestResult = result
                    self?.detail = "网络测试完成：\(String(format: "%.1f", result.throughputMbps)) Mbps"
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

    private func updateOverallDetail() {
        guard !sessions.isEmpty else {
            detail = "等待已配对的 MatePad 发起投屏"
            return
        }
        let castingCount = sessions.filter { $0.state == .casting }.count
        detail = castingCount == sessions.count
            ? "正在接收 \(sessions.count) 路投屏"
            : "正在建立投屏（\(castingCount)/\(sessions.count) 路已显示）"
    }

    private func clearAllSessions() {
        sessions.forEach { $0.reset() }
        sessions.removeAll()
        ScreenCastWindowRegistry.closeAll()
    }
}
