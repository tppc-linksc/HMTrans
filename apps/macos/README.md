# Mac 端

Mac 端包含 Swift 共享传输核心、命令行测试入口和 SwiftUI 图形入口。

当前已完成 `v0.1` 基础能力，v0.2 方案已经整理，下一步按仓库 `docs/` 重构传输引擎和状态栏体验。


## 系统适配基线

- 目标系统为 macOS 26 及以上。
- 优先使用 SwiftUI / AppKit 原生能力，不为旧 macOS 牺牲当前设计。
- UI 需要适配深浅色模式、系统材质、菜单栏、Dock 拖拽和窗口恢复。

## 当前能力

- 启动后自动常驻监听 TCP 端口。
- UDP 自动发现同一局域网 HMTrans 设备。
- 自动记住上次连接设备。
- 支持选择文件发送。
- 支持拖文件/文件夹到窗口发送。
- 支持拖文件/文件夹到 Dock 图标发送。
- 文件夹会临时压缩为 zip 后传输。
- 接收前确认，已信任设备自动接收。
- SHA-256 校验。
- 默认保存到 `~/Downloads/HMTrans`。
- 当前传输和历史记录显示速度、大小、格式、方向和结果。
- 菜单栏图标常驻入口。

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

当前构建为未签名分发版本，没有 `Developer ID` 签名和 Apple notarization。别人下载后首次打开可能会被 macOS 安全策略拦截，需要右键 `Open` 或在系统“隐私与安全性”中手动允许。

上传到 GitHub Release 的附件文件名需要固定为 `HMTrans.dmg`，以保证官网直链可用。

## v0.2 Mac 重点

- 把发现、接收、发送和任务状态从窗口 ViewModel 拆到应用级协调器。
- 使用系统 SQLite3 保存任务、检查点、设备和历史；身份密钥使用 Keychain。
- 窗口关闭、状态栏面板关闭和 Mac 睡眠唤醒后保持或恢复任务。
- 重绘原生模板状态栏图标，以 AppKit `NSStatusItem` + `NSPanel` 实现拖拽快速发送和悬浮任务列表。
- Finder、Dock、主窗口和状态栏拖拽必须共用同一持久任务入口。
- 移除空闲高频广播、RunLoop 唤醒和每秒设备轮询。

完整范围见：

- `../../docs/01-v0.2产品与交互方案.md`
- `../../docs/02-v0.2技术方案.md`
- `../../docs/03-传输协议-v0.2.md`
- `../../docs/04-v0.2开发计划.md`
- `../../docs/05-v0.2验收清单.md`
