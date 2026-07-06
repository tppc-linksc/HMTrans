# HarmonyOS 端

HarmonyOS 端是一个 DevEco / hvigor 工程，用 ArkTS + ArkUI 实现 MatePad 和 Mac 的原文件互传。

当前处于 `v0.1` 发版前调试阶段。


## 系统适配基线

- 目标系统为 HarmonyOS 6.1.0 / API 23 及以上。
- 优先使用 ArkTS / ArkUI / HarmonyOS 原生能力，不再按 HarmonyOS 5.0 的最低能力做设计。
- UI 需要适配平板全屏、分屏、小窗、拖拽、沉浸式界面和新系统视觉特性。

## 当前能力

- 启动后自动开启接收服务。
- UDP 自动发现 Mac。
- 记住上次连接的 Mac。
- 调用系统文件选择器选择文件。
- 支持拖拽文件发送。
- 支持接收 Mac 发来的文件。
- 接收前弹窗确认，已信任设备自动接收。
- 文件夹会压缩为 zip 后发送。
- 优先保存接收文件到系统下载目录 `Download/PureSend`；如果下载目录权限不可用，才退回应用目录。
- 显示当前传输、历史记录、速度、大小、格式、方向和结果。
- 完成后做 SHA-256 校验。

## 技术要点

- UI：ArkUI。
- 语言：ArkTS。
- 网络：UDP 自动发现 + TCP 文件传输。
- 文件选择：系统 Picker。
- 文件保存：应用沙箱目录优先。
- 校验：SHA-256。

## 当前文件

```text
build-profile.example.json5
hvigorfile.ts
entry/src/main/module.json5
entry/src/main/ets/entryability/EntryAbility.ets
entry/src/main/ets/common/Protocol.ets
entry/src/main/ets/common/Bytes.ets
entry/src/main/ets/services/FileHashService.ets
entry/src/main/ets/services/TcpTransferService.ets
entry/src/main/ets/services/DiscoveryService.ets
entry/src/main/ets/pages/Index.ets
docs/ArkTS-实现说明.md
```

## 构建

首次克隆后，先复制本地构建配置：

```sh
cp build-profile.example.json5 build-profile.json5
```

`build-profile.json5` 可能包含本机签名证书路径和密码，已加入 `.gitignore`，不要提交。

```sh
cd apps/harmonyos
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \\
  /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleHap --mode module -p module=entry@default -p product=default
```

产物：

```text
entry/build/default/outputs/default/entry-default-unsigned.hap
entry/build/default/outputs/default/entry-default-signed.hap
```

真机安装建议直接用 DevEco Studio Run 到 MatePad。

## 安装失败处理

如果 DevEco 安装时报：

```text
Install Failed: error: failed to install bundle.
error: install sign info inconsistent.
```

说明 MatePad 上已经安装过同 bundleName `com.linksc.puresend` 但签名证书不同的旧版本。先卸载旧包，再重新 Run：

```sh
hdc shell bm uninstall -n com.linksc.puresend
```

如果 DevEco 仍然复用旧状态，直接在平板上长按 PureSend 图标卸载一次，然后再用 DevEco Studio Run。

## v0.2 待做

- 一对多连接和群组发送。
- 文件夹语义传输：用户发送文件夹，接收端最终得到文件夹。
- 断点续传，传输中支持暂停和停止。
- 读取并展示连接设备的完整设备名称和系统版本。
- 配对码。
- 失败文件 UI 和续传入口。
- 历史记录支持删除单条记录和清空全部记录。
- 后台保活和后台传输保证：使用 HarmonyOS 6.1/API 23+ 后台任务能力，传输过程中退到后台或短时间锁屏不应中断。
- 接收文件保存到系统可见目录或媒体库的方案。
