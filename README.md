# HMTrans

HMTrans（中文名：HM互传）是一个面向 macOS 和华为 MatePad / HarmonyOS 的局域网原文件互传工具。两端在同一 Wi-Fi 下直接发现、连接和传输文件，不经过云端。

## 项目背景

这个工具来自我在做其他项目时遇到的传输困境：Mac 和 MatePad 之间临时传文件、截图、项目素材时，常见方案要么依赖云同步，要么步骤太多，要么不能稳定保留原文件。HMTrans 是一个 vibecoding 产品，目标很明确：把我自己每天常用的 Mac <-> MatePad 统一局域网下互传原始文件链路做顺手。

当前稳定版为 `v0.2.1`：macOS 版通过 GitHub Release 分发，HarmonyOS 版已经提交应用市场审核，公开状态以应用市场结果为准。开发分支 `codex/v0.3.0-screen-cast` 已完成 MatePad 到 Mac 单向投屏的双端代码、协议测试与构建，正在进入真机验收。项目始终坚持局域网直连，不增加云端和账号系统。

## 功能概览

- 同一 Wi-Fi 下自动发现 macOS 和 HarmonyOS 设备。
- 支持 Mac 拖拽或点击选择文件/文件夹发送，Pad 通过系统选择器选择文件/文件夹发送。
- 支持任意文件类型；文件夹在应用私有目录临时归档，接收端校验后自动还原，不向用户展示内部 zip 或分片。
- 双端显示当前传输、历史记录、进度、速度、大小、格式和结果。
- 首次连接必须输入对端 180 秒有效的六位配对码；正常覆盖升级会保留应用身份和信任并自动重连，清除应用数据后必须重新配对。
- 支持一对多发送，同一批文件对每台设备维护独立进度、结果和断点。
- 传输使用 TCP 原始文件流，完成后做 SHA-256 校验。
- 默认保存到 Mac 的 `~/Downloads/HMTrans` 和 HarmonyOS 的 `Download/HMTrans`。

## 当前界面

双端当前都使用“连接 / 历史 / 设置”三个一级入口；发送区域位于连接页，活动任务与结束记录统一进入历史页。稳定版交互以当前代码为准；下一版本的入口、状态和边界见 [v0.3 产品与交互方案](docs/02-v0.3产品与交互方案.md)。

## 开源协议

本项目基于 [MIT License](LICENSE) 开源。

## 版本状态

当前已发布的 macOS Release 为 `v0.2.1`；HarmonyOS 使用相同对外版本号提交应用市场审核。稳定版文件互传继续维护。v0.3 投屏已经完成开发构建，但尚未完成真机验收或公开发布，不能把开发分支能力描述成稳定版功能。

稳定版文件互传包括：

- 引入本地数据库、私有持久临时文件和统一状态机。
- 支持暂停、继续、取消、断点续传、后台传输和进程重启恢复。
- 完成文件才发布到 `Download/HMTrans`，用户默认看不到未完成分片。
- 使用应用自己的隐私弹窗，同意前不启动局域网服务。
- 支持六位配对码、已配对设备、多设备群发和文件夹自动还原。
- 增加任务控制、错误码、诊断信息、记录清理和临时空间管理。
- 重做 Mac 状态栏图标和快捷任务面板，Finder、Dock、窗口入口复用同一发送任务链路。
- 治理空闲广播、定时器和 UI 刷新造成的能耗。

完整定义见 [HMTrans 文档索引](docs/README.md)。

## v0.3 开发方向

`v0.3.0` 计划在已配对设备之间加入 MatePad 到 Mac 的单向画面投放：Pad 经 HarmonyOS 系统录屏授权后使用原生 H.264 编码，Mac 使用 VideoToolbox 解码并在独立窗口中显示。它用于应用演示和配合 macOS 系统录屏，不把 Pad 作为副屏，也不在 HMTrans 内保存录像。

- 继续使用“连接 / 历史 / 设置”三个一级入口，不新增投屏主 Tab。
- 首版支持画面、横竖屏、全屏、停止、有限重连和诊断。
- 首版不包含声音、触控、键盘、鼠标、内置录制、云端或公网中继。
- 文件传输与投屏使用独立协议和端口；投屏不生成文件历史或临时视频。
- 后续 `v0.3.x` 再根据真机结果优化画质、延迟、声音和反向控制。

版本历史和后续路线见 [版本演进](docs/01-版本演进.md)。

## 系统适配基线

- HarmonyOS 端以 HarmonyOS 6.1.0 / API 23 及以上为目标，不再按 HarmonyOS 5.0 的最低能力设计交互和能力边界。
- HarmonyOS 端优先使用 ArkTS / ArkUI / HarmonyOS 原生能力，包括窗口化/分屏适配、拖拽、沉浸式界面、系统文件能力、后台任务和新系统视觉特性。
- macOS 端以 macOS 26 及以上为目标，优先使用 SwiftUI、AppKit、菜单栏、Dock 拖拽、系统材质、深浅色模式和新系统原生能力。
- 兼容旧系统不是当前优先级；如果某个新系统 API 会明显改善体验，优先按新系统实现，再在文档中说明最低系统要求。

## 当前接收文件位置

- Mac：默认保存到 `~/Downloads/HMTrans`，后续可配置。
- HarmonyOS：启动后申请下载目录读写权限，并在系统下载目录创建 `HMTrans` 文件夹；接收文件默认直接保存到 `Download/HMTrans`，文件管理器可见。若系统拒绝下载目录权限或目录不可写，接收服务不会启动，避免文件落到不可见缓存目录。

## 仍需持续真机验收

- 应用市场正式签名包干净安装后，验证自有隐私同意完成才出现下载目录系统授权；拒绝后可从设置重新申请，且发现/发送不被目录授权阻断。
- 使用多 GB 文件验证切后台、短时锁屏、断网重连、应用重启和断点一致性。
- 使用三台真实设备验证 A-B、B-C 已连接而 A-C 未连接时不会错误中继或错误标记连接。
- 使用大量小文件、嵌套文件夹和多个并发接收端记录 CPU、内存、能耗和磁盘峰值。
- HAP 安装依赖匹配的调试或正式签名；设备已有不同签名同包名应用时，系统不会允许直接覆盖。

## 目录结构

```text
HMTrans/
  README.md
  docs/
    README.md
    00-项目说明.md
    01-版本演进.md
    02-v0.3产品与交互方案.md
    03-v0.3技术方案.md
    04-v0.3投屏协议.md
    05-v0.3开发计划.md
    06-v0.3验收清单.md
    07-v0.3发布前检查报告.md
  apps/
    macos/
      Package.swift
      Sources/
        HMTransCore/
        HMTransMacCLI/
        HMTransMacApp/
    harmonyos/
      build-profile.example.json5
      docs/
        v0.3-投屏实现说明.md
      entry/src/main/ets/
        common/
        components/
        controllers/
        models/
        pages/
        persistence/
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

当前脚本只做 ad-hoc 本地签名：可以生成 `.app` 和 `.dmg`，但因为没有 `Developer ID` 和 Apple notarization，其他 Mac 首次打开时可能出现“无法验证开发者”或安全提醒，用户需要右键 `Open` 或在系统“隐私与安全性”中手动允许。项目不会把 ad-hoc 签名描述成正式开发者签名。

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
      /Applications/DevEco-Studio.app/Contents/tools/node/bin/node \
      /Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/bin/hvigor.js \
      --no-daemon --mode module -p module=entry@default -p product=default assembleHap
```

产物位置：

```text
apps/harmonyos/entry/build/default/outputs/default/entry-default-signed.hap
apps/harmonyos/entry/build/default/outputs/default/entry-default-unsigned.hap
```

HAP 不能像 APK 一样无条件安装到任意设备。真机安装通常需要 DevEco Studio 调试签名，或使用匹配证书重新签名。
