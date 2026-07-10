# HMTrans

HMTrans（中文名：HM互传）是一个面向 macOS 和华为 MatePad / HarmonyOS 的局域网原文件互传工具。两端在同一 Wi-Fi 下直接发现、连接和传输文件，不经过云端。

## 项目背景

这个工具来自我在做其他项目时遇到的传输困境：Mac 和 MatePad 之间临时传文件、截图、项目素材时，常见方案要么依赖云同步，要么步骤太多，要么不能稳定保留原文件。HMTrans 是一个 vibecoding 产品，目标很明确：把我自己每天常用的 Mac <-> MatePad 统一局域网下互传原始文件链路做顺手。

`v0.1` 已完成首次分发，v0.2 的产品、技术、协议、开发计划和验收方案已经整理，功能尚待实现。v0.2 聚焦后台可靠、断点续传、人工控制、错误诊断、多设备和 Mac 状态栏快捷发送；项目仍然只做局域网本地传输，不增加云端和账号系统。

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

当前已发布版本是 `v0.1`：支持双端原生应用、局域网发现、一对一 TCP 文件流、文件/文件夹发送、基础信任、进度历史和 SHA-256 校验。Mac 端通过 GitHub Release 分发，HarmonyOS 端已通过应用市场分发，当前仅支持 Pad。

`v0.2` 是当前目标版本：

- 引入本地数据库、私有持久临时文件和统一状态机。
- 支持暂停、继续、取消、断点续传、后台传输和进程重启恢复。
- 完成文件才发布到 `Download/HMTrans`，用户默认看不到未完成分片。
- 使用应用自己的隐私弹窗，同意前不启动局域网服务。
- 支持六位配对码、已配对设备、多设备群发和文件夹自动还原。
- 增加任务控制、错误码、诊断信息、记录清理和临时空间管理。
- 重做 Mac 状态栏图标，支持拖文件到状态栏快速发送和悬浮查看任务进度。
- 治理空闲广播、定时器和 UI 刷新造成的能耗。

完整定义见 [HMTrans 文档索引](docs/README.md)。

## 系统适配基线

- HarmonyOS 端以 HarmonyOS 6.1.0 / API 23 及以上为目标，不再按 HarmonyOS 5.0 的最低能力设计交互和能力边界。
- HarmonyOS 端优先使用 ArkTS / ArkUI / HarmonyOS 原生能力，包括窗口化/分屏适配、拖拽、沉浸式界面、系统文件能力、后台任务和新系统视觉特性。
- macOS 端以 macOS 26 及以上为目标，优先使用 SwiftUI、AppKit、菜单栏、Dock 拖拽、系统材质、深浅色模式和新系统原生能力。
- 兼容旧系统不是当前优先级；如果某个新系统 API 会明显改善体验，优先按新系统实现，再在文档中说明最低系统要求。

## 当前接收文件位置

- Mac：默认保存到 `~/Downloads/HMTrans`，后续可配置。
- HarmonyOS：启动后申请下载目录读写权限，并在系统下载目录创建 `HMTrans` 文件夹；接收文件默认直接保存到 `Download/HMTrans`，文件管理器可见。若系统拒绝下载目录权限或目录不可写，接收服务不会启动，避免文件落到不可见缓存目录。

## 当前 v0.1 已知限制

- `v0.1` 只保证一对一传输，不做一对多和群组发送。
- `v0.1` 不做配对码，仍使用首次信任确认。
- `v0.1` 文件夹接收结果可能是 zip 包；`v0.2` 要改成接收结果仍是文件夹。
- `v0.1` 不做断点续传，大文件中断后需要重新传。
- HarmonyOS 锁屏或系统省电可能暂停应用网络活动，重新点亮后依赖发现广播重连。
- HarmonyOS `v0.1` 应用市场版首次启动可能因旧隐私流程与下载目录初始化时序冲突，导致下载目录未初始化，并进一步阻断 TCP 接收和 UDP 设备发现；该问题已纳入 `v0.2` 第一阶段。
- `v0.1` 后台传输仍按系统能力尽力保活，后台/锁屏期间不承诺绝对不中断；`v0.2` 要把后台传输保证和断点续传一起做完整。
- HAP 安装依赖调试签名或正式签名；虚拟机/真机已有不同签名同包名应用时，需要先卸载旧包。

## 目录结构

```text
HMTrans/
  README.md
  docs/
    README.md
    00-项目说明.md
    01-v0.2产品与交互方案.md
    02-v0.2技术方案.md
    03-传输协议-v0.2.md
    04-v0.2开发计划.md
    05-v0.2验收清单.md
    06-发版流程.md
    07-宣传视频脚本.md
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

打包 `.dmg`：

```sh
bash apps/macos/scripts/build-dmg.sh
```

产物位置：

```text
apps/macos/build/HMTrans.dmg
```

当前仓库只提供未签名分发构建：可以直接生成 `.app` 和 `.dmg`，也可以通过 GitHub Release 分发，但因为没有 `Developer ID` 签名和 Apple notarization，其他 Mac 首次打开时可能出现“无法验证开发者”或安全提醒，用户需要右键 `Open` 或在系统“隐私与安全性”中手动允许。

GitHub Release 附件文件名需要固定为 `HMTrans.dmg`，官网直接下载链接依赖这个文件名。

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
