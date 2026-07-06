# PureSend

PureSend 是一个面向自用和开源分享的局域网原文件互传工具，目标是在同一 Wi-Fi 下，让 macOS 和华为 MatePad / HarmonyOS 设备直接互传原始文件。

本项目是自用优先的开源项目，主要解决 Mac 与 MatePad 在同一 Wi-Fi 下快速互传原文件的问题。当前版本仍处在 `v0.1.0` 发版前真机调试阶段，欢迎有相同需求的人一起验证和改进。

## 开源协议

本项目基于 [MIT License](LICENSE) 开源。

## 截图

发版前建议放入两张干净截图，避免包含个人桌面、聊天内容、文件名或网络信息：

- `docs/images/macos-main.png`：macOS 主界面，展示拖拽区、附近设备、当前传输和历史记录。
- `docs/images/harmonyos-main.png`：HarmonyOS 主界面，展示平板横屏或窗口化效果。

当前仓库暂不放入调试过程中带红色标注的截图，避免开源时泄漏个人界面信息。

## 版本状态

## 系统适配基线

- HarmonyOS 端以 HarmonyOS 6.1.0 / API 23 及以上为目标，不再按 HarmonyOS 5.0 的最低能力设计交互和能力边界。
- HarmonyOS 端优先使用 ArkTS / ArkUI / HarmonyOS 原生能力，包括窗口化/分屏适配、拖拽、沉浸式界面、系统文件能力、后台任务和新系统视觉特性。
- macOS 端以 macOS 26 及以上为目标，优先使用 SwiftUI、AppKit、菜单栏、Dock 拖拽、系统材质、深浅色模式和新系统原生能力。
- 兼容旧系统不是当前优先级；如果某个新系统 API 会明显改善体验，优先按新系统实现，再在文档中说明最低系统要求。

当前代码处于 `v0.1` 发版前调试阶段。等 Mac 端和 MatePad 真机链路全部确认稳定后，发布第一个开源版本 `v0.1`。

`v0.1` 的定位是“一对一可用”：

- Mac 与 MatePad 双端原生应用。
- 同一局域网 UDP 自动发现设备。
- TCP 原始文件流传输，不经过云端。
- 支持文件和文件夹发送；文件夹会临时压缩为 zip 后传输。
- 首次接收或首次连接需要确认，已信任设备后续自动连接/接收。
- 当前传输显示进度、速度、方向；历史记录显示大小、格式、平均速度和结果。
- SHA-256 完整性校验通过后才标记成功。

`v0.2` 的定位是“多设备与失败恢复”：

- 一对多连接和群组发送。
- 文件夹语义传输：允许内部压缩，但接收端还原为文件夹，用户不感知 zip 过程。
- 断点续传，传输中支持暂停和停止。
- 已连接过的设备再次连接时恢复相关传输记录，与断点续传状态一起保留。
- 读取并展示连接设备的完整设备名称和系统版本。
- 配对码确认，替代单纯信任弹窗。
- 失败文件 UI 展示，支持从失败记录继续/重试。
- 常见文件类型图标和缩略图：按扩展名匹配图片、视频、文档、压缩包等图标，能安全读取时优先展示真实缩略图。
- 历史记录支持删除单条记录和清空全部记录。
- 后台保活和后台传输保证：传输过程中退到后台或短时间锁屏不应中断；系统强制中断后可恢复。

## 当前接收文件位置

- Mac：默认保存到 `~/Downloads/PureSend`，后续可配置。
- HarmonyOS：启动后申请下载目录读写权限，并在系统下载目录创建 `PureSend` 文件夹；接收文件默认直接保存到 `Download/PureSend`，文件管理器可见。若系统拒绝下载目录权限或目录能力不可用，才退回应用缓存。

## 已知限制

- `v0.1` 只保证一对一传输，不做一对多和群组发送。
- `v0.1` 不做配对码，仍使用首次信任确认。
- `v0.1` 文件夹接收结果可能是 zip 包；`v0.2` 要改成接收结果仍是文件夹。
- `v0.1` 不做断点续传，大文件中断后需要重新传。
- HarmonyOS 锁屏或系统省电可能暂停应用网络活动，重新点亮后依赖发现广播重连。
- `v0.1` 后台传输仍按系统能力尽力保活，后台/锁屏期间不承诺绝对不中断；`v0.2` 要把后台传输保证和断点续传一起做完整。
- HAP 安装依赖调试签名或正式签名；虚拟机/真机已有不同签名同包名应用时，需要先卸载旧包。

## 目录结构

```text
PureSend/
  README.md
  docs/
    00-项目说明.md
    01-技术方案.md
    02-传输协议-v0.1.md
    03-开发计划.md
  apps/
    macos/
      Package.swift
      Sources/
        PureSendCore/
        PureSendMacCLI/
        PureSendMacApp/
    harmonyos/
      build-profile.example.json5
      entry/src/main/ets/
        common/
        pages/
        services/
```

## Mac 端构建

调试运行：

```sh
swift run --package-path apps/macos PureSendMac
```

打包 `.app`：

```sh
bash apps/macos/scripts/build-app.sh
```

产物位置：

```text
apps/macos/build/PureSend.app
```

开源分发时建议后续补充 Developer ID 签名和 notarization；未签名 `.app` 在其他 Mac 上可能需要手动允许打开。

## HarmonyOS 端构建

推荐用 DevEco Studio 打开：

```text
apps/harmonyos
```

命令行构建：

```sh
cd apps/harmonyos
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \\
  /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleHap --mode module -p module=entry@default -p product=default
```

产物位置：

```text
apps/harmonyos/entry/build/default/outputs/default/entry-default-signed.hap
apps/harmonyos/entry/build/default/outputs/default/entry-default-unsigned.hap
```

HAP 不能像 APK 一样无条件安装到任意设备。真机安装通常需要 DevEco Studio 调试签名，或使用匹配证书重新签名。
