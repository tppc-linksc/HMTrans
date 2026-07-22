# Mac 端

Mac 端包含 Swift 共享传输核心、命令行测试入口和 SwiftUI 图形入口。

当前稳定版为 `v0.3.0`。本目录实现了持久任务、暂停/继续/取消、断点恢复、六位码配对、文件夹还原、多设备并发发送、诊断、单实例保护和状态栏快捷入口，并正式加入投屏接收、H.264 解码、独立观看窗口、画中画和全屏。macOS 构建、协议测试和目标设备投屏流程已经通过。


## 系统适配基线

- 目标系统为 macOS 26 及以上。
- 优先使用 SwiftUI / AppKit 原生能力，不为旧 macOS 牺牲当前设计。
- UI 需要适配深浅色模式、系统材质、菜单栏、Dock 拖拽和窗口恢复。

## 当前能力

- 用户同意应用自有隐私说明后，自动启动 TCP 接收和 UDP 发现。
- UDP 自动发现同一局域网 HMTrans 设备。
- 自动记住上次连接设备。
- 支持选择文件发送。
- 支持拖文件/文件夹到窗口发送。
- 支持拖文件/文件夹到 Dock 图标发送。
- 文件夹在 Application Support 私有 Staging 中归档，接收端校验后自动还原同名文件夹。
- 接收前确认，已信任设备自动接收。
- SHA-256 校验。
- 默认保存到 `~/Downloads/HMTrans`。
- 当前传输和历史记录显示速度、大小、格式、方向和结果。
- 菜单栏图标常驻入口。
- 设置中的接收、发现、自动接收和后台保护开关分别驱动真实服务状态。

## 运行

启动图形端：

```sh
swift run --package-path apps/macos HMTransMac
```

CLI 接收：

```sh
cd apps/macos
swift run hmtrans receive
```

CLI 发送：

```sh
cd apps/macos
swift run hmtrans send --host 192.168.1.35 --file ~/Desktop/example.DNG
```

## 打包

```sh
bash apps/macos/scripts/build-app.sh
```

产物：

```text
apps/macos/build/HMTrans.app
```

如需生成用于 GitHub Release 分发的磁盘镜像：

```sh
bash apps/macos/scripts/build-dmg.sh
```

产物：

```text
apps/macos/build/HMTrans.dmg
```

当前构建仅使用 ad-hoc 本地签名，没有 `Developer ID` 签名和 Apple notarization。别人下载后首次打开可能会被 macOS 安全策略拦截，需要右键 `Open` 或在系统“隐私与安全性”中手动允许。

上传到 GitHub Release 的附件文件名需要固定为 `HMTrans.dmg`，以保证官网直链可用。

## 稳定版实现

- `TransferViewModel` 按发现、文件入口和任务状态扩展拆分，socket、持久化、并发门、后台活动和状态栏面板由独立服务持有。
- 使用系统 SQLite3 增量保存任务、设备、历史和诊断；随机安装指纹和设备信任关系保存在当前用户的本地偏好，不是账号或硬件密钥。
- 窗口关闭、状态栏面板关闭和 Mac 睡眠唤醒后保持或恢复任务。
- 重绘原生模板状态栏图标，以 AppKit `NSStatusItem` + `NSPanel` 实现拖拽快速发送和悬浮任务列表。
- Finder、Dock、主窗口和状态栏拖拽必须共用同一持久任务入口。
- 已移除活动传输之外的防休眠声明，并对发现和界面刷新降频。
- 长时间后台、多 GB 文件、睡眠唤醒、多屏状态栏拖放和三设备场景继续按真机回归要求维护。

## v0.3 Mac 投屏实现

- 已增加独立 `ScreenCastReceiverService`，监听单独的投屏协议端口，不复用文件接收器。
- 使用 VideoToolbox 解码 H.264，通过原生视频图层在独立窗口显示。
- 仅接受已配对 Pad 使用本地共享密钥建立的加密会话，不提供额外的自动接受开关。
- 支持适应窗口、原始比例、画中画、全屏、会话统计和停止。
- 主窗口关闭不终止观看窗口；睡眠、应用退出和接收关闭会明确结束会话。
- 首版不采集 Mac 屏幕、不回传键鼠、不保存视频，也不改变文件传输历史。
- 当前代码、构建、协议测试和目标 MatePad 核心投屏流程已完成；更多设备、长时间投屏和复杂网络继续作为发布后回归项目。

实现与后续维护以本目录源码、测试、根 README 和 `docs/` 中的公开基础说明为准；个人工作资料不随仓库发布。
