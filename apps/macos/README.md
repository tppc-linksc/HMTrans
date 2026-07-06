# Mac 端

Mac 端包含 Swift 共享传输核心、命令行测试入口和 SwiftUI 图形入口。

当前处于 `v0.1` 发版前调试阶段。


## 系统适配基线

- 目标系统为 macOS 26 及以上。
- 优先使用 SwiftUI / AppKit 原生能力，不为旧 macOS 牺牲当前设计。
- UI 需要适配深浅色模式、系统材质、菜单栏、Dock 拖拽和窗口恢复。

## 当前能力

- 启动后自动常驻监听 TCP 端口。
- UDP 自动发现同一局域网 PureSend 设备。
- 自动记住上次连接设备。
- 支持选择文件发送。
- 支持拖文件/文件夹到窗口发送。
- 支持拖文件/文件夹到 Dock 图标发送。
- 文件夹会临时压缩为 zip 后传输。
- 接收前确认，已信任设备自动接收。
- SHA-256 校验。
- 默认保存到 `~/Downloads/PureSend`。
- 当前传输和历史记录显示速度、大小、格式、方向和结果。
- 菜单栏图标常驻入口。

## 运行

启动图形端：

```sh
swift run --package-path apps/macos PureSendMac
```

CLI 接收：

```sh
cd apps/macos
swift run puresend receive
```

CLI 发送：

```sh
cd apps/macos
swift run puresend send --host 192.168.1.35 --file ~/Desktop/example.DNG
```

## 打包

```sh
bash apps/macos/scripts/build-app.sh
```

产物：

```text
apps/macos/build/PureSend.app
```

## v0.2 待做

- 一对多连接和群组发送。
- 文件夹语义传输：用户发送文件夹，接收端最终得到文件夹。
- 断点续传，传输中支持暂停和停止。
- 读取并展示连接设备的完整设备名称和系统版本。
- 配对码。
- 失败文件 UI 和续传入口。
- 历史记录支持删除单条记录和清空全部记录。
- 后台保活和后台传输保证：菜单栏常驻，窗口关闭不影响发送、接收和进度更新。
- 系统通知和更完整的后台/重连策略。
