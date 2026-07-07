# HMTrans

HMTrans（中文名：HM互传）是一个面向 macOS 和华为 MatePad / HarmonyOS 的局域网原文件互传工具。两端在同一 Wi-Fi 下直接发现、连接和传输文件，不经过云端。

## 项目背景

这个工具来自我在做其他项目时反复遇到的传输困境：Mac 和 MatePad 之间临时传文件、截图、安装包或项目素材时，常见方案要么依赖云同步，要么步骤太多，要么不能稳定保留原文件。HMTrans 是一个 vibecoding 产品，目标很明确：把我自己每天最常用的 Mac <-> MatePad 互传链路做顺手。

当前版本已经能覆盖我大约 95% 的日常使用场景，但还没有做深度测试，也不承诺适合所有网络环境。后续会继续做 `v0.2`，不过短期内我还有其他事情要忙，不会高频更新。欢迎有同样需求的人一起开发、测试和优化。

## 功能概览

- 同一 Wi-Fi 下自动发现 macOS 和 HarmonyOS 设备。
- 支持 Mac 拖拽或点击选择文件发送，Pad 点击选择文件发送。
- 支持任意文件类型；文件夹会临时压缩为 zip 后传输。
- 双端显示当前传输、历史记录、进度、速度、大小、格式和结果。
- 首次连接或首次接收需要确认，信任后自动连接/接收。
- 传输使用 TCP 原始文件流，完成后做 SHA-256 校验。
- 默认保存到 Mac 的 `~/Downloads/HMTrans` 和 HarmonyOS 的 `Download/HMTrans`。

## 截图

### macOS

![HMTrans macOS 主界面](docs/images/macos-main.png)

### HarmonyOS / MatePad

![HMTrans HarmonyOS 主界面](docs/images/harmonyos-main.png)

## 开源协议

本项目基于 [MIT License](LICENSE) 开源。

## 版本状态

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
- 传输记录支持左滑删除单条记录，并支持清空全部记录。
- 后台保活和后台传输保证：传输过程中退到后台或短时间锁屏不应中断；系统强制中断后可恢复。

## 系统适配基线

- HarmonyOS 端以 HarmonyOS 6.1.0 / API 23 及以上为目标，不再按 HarmonyOS 5.0 的最低能力设计交互和能力边界。
- HarmonyOS 端优先使用 ArkTS / ArkUI / HarmonyOS 原生能力，包括窗口化/分屏适配、拖拽、沉浸式界面、系统文件能力、后台任务和新系统视觉特性。
- macOS 端以 macOS 26 及以上为目标，优先使用 SwiftUI、AppKit、菜单栏、Dock 拖拽、系统材质、深浅色模式和新系统原生能力。
- 兼容旧系统不是当前优先级；如果某个新系统 API 会明显改善体验，优先按新系统实现，再在文档中说明最低系统要求。

## 当前接收文件位置

- Mac：默认保存到 `~/Downloads/HMTrans`，后续可配置。
- HarmonyOS：启动后申请下载目录读写权限，并在系统下载目录创建 `HMTrans` 文件夹；接收文件默认直接保存到 `Download/HMTrans`，文件管理器可见。若系统拒绝下载目录权限或目录不可写，接收服务不会启动，避免文件落到不可见缓存目录。

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
HMTrans/
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
        HMTransCore/
        HMTransMacCLI/
        HMTransMacApp/
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
swift run --package-path apps/macos HMTransMac
```

打包 `.app`：

```sh
bash apps/macos/scripts/build-app.sh
```

产物位置：

```text
apps/macos/build/HMTrans.app
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
