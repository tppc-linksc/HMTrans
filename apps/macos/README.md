# Mac 端

Mac 端包含 Swift 共享传输核心、命令行测试入口和 SwiftUI 图形入口。

当前公开版本为 `v0.1`；本目录代码为 `v0.2.0` 发布候选，已实现持久任务、暂停/继续/取消、断点恢复、六位码配对、文件夹还原、多设备并发发送、诊断和状态栏快捷入口。


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

## v0.2 Mac 实现与待验收

- `TransferViewModel` 按发现、文件入口和任务状态扩展拆分，socket、持久化、并发门、后台活动和状态栏面板由独立服务持有。
- 使用系统 SQLite3 增量保存任务、设备、历史和诊断；随机安装指纹和设备信任关系保存在当前用户的本地偏好，不是账号或硬件密钥。
- 窗口关闭、状态栏面板关闭和 Mac 睡眠唤醒后保持或恢复任务。
- 重绘原生模板状态栏图标，以 AppKit `NSStatusItem` + `NSPanel` 实现拖拽快速发送和悬浮任务列表。
- Finder、Dock、主窗口和状态栏拖拽必须共用同一持久任务入口。
- 已移除活动传输之外的防休眠声明，并对发现和界面刷新降频。
- 待验收：多 GB 文件、Mac 睡眠唤醒、多屏状态栏拖放、三台设备并发和空闲能耗。

完整范围见：

- `../../docs/01-v0.2产品与交互方案.md`
- `../../docs/02-v0.2技术方案.md`
- `../../docs/03-v0.2传输协议.md`
- `../../docs/04-v0.2开发计划.md`
- `../../docs/05-v0.2验收清单.md`
