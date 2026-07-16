import AppKit
import SwiftUI

/// 自有隐私门；用户同意前不启动发现、接收器或状态栏入口。
struct PrivacyGateView: View {
    private static let privacyVersion = "2026-07-16"
    let model: TransferViewModel
    @AppStorage("privacyAcceptedVersion") private var acceptedVersion = ""

    var body: some View {
        Group {
            if acceptedVersion == Self.privacyVersion {
                ContentView(model: model)
                    .onAppear(perform: startLocalServices)
            } else {
                consentPage
            }
        }
    }

    private var consentPage: some View {
        ZStack {
            MacAppTheme.windowBackground.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("使用 HM互传前，请阅读隐私说明")
                        .font(.system(size: 24, weight: .bold))
                    Text("HM互传只在同一局域网的设备之间传输用户主动选择的文件；v0.3 还可接收用户从 MatePad 主动发起并经系统授权的实时屏幕画面。应用不提供账号、云盘或云端中转。")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 9) {
                    Label("同意后才启动局域网发现和文件接收服务", systemImage: "network")
                    Label("设备名称、系统版本和局域网地址会发送给同网段 HM互传设备", systemImage: "desktopcomputer")
                    Label("任务、历史和配对关系只保存在本机", systemImage: "internaldrive")
                    Label("投屏画面只在内存中解码显示，不保存为视频或截图", systemImage: "rectangle.on.rectangle")
                }
                .font(.system(size: 12, weight: .medium))
                if let privacyURL = URL(string: "https://hmt.tppc.top/privacy.html") {
                    Link("查看完整隐私政策", destination: privacyURL)
                        .font(.system(size: 12, weight: .semibold))
                }
                HStack {
                    Button("不同意并退出") { NSApp.terminate(nil) }
                    Spacer()
                    Button("同意并继续") {
                        acceptedVersion = Self.privacyVersion
                        startLocalServices()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(28)
            .frame(width: 520)
            .glassCard(radius: 22)
        }
    }

    private func startLocalServices() {
        model.bootstrap()
        MacStatusItemController.shared.install(model: model)
    }
}
