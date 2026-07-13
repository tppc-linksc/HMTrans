# HarmonyOS 端

HarmonyOS 端是 HM互传 的 DevEco / hvigor 工程，用 ArkTS + ArkUI 实现 MatePad 和 Mac 的原文件互传。

当前应用市场公开版本为 `v0.1`；本目录代码为 `v0.2.0` 发布候选，已完成自有隐私门禁、持久任务、断点恢复、文件夹还原、多设备发送、任务控制和活动传输后台保护。正式市场包的干净安装、锁屏后台和超大文件仍须按验收报告实测。


## 系统适配基线

- 目标系统为 HarmonyOS 6.1.0 / API 23 及以上。
- 优先使用 ArkTS / ArkUI / HarmonyOS 原生能力，不再按 HarmonyOS 5.0 的最低能力做设计。
- UI 需要适配平板全屏、分屏、小窗、拖拽、沉浸式界面和新系统视觉特性。

## 当前能力

- 首次同意应用自有隐私政策后，再请求下载目录系统授权并启动服务。
- UDP 自动发现 Mac。
- 记住上次连接的 Mac。
- 调用系统文件选择器选择文件或文件夹；只读取用户主动选择的内容。
- 支持拖拽文件发送。
- 支持接收 Mac 发来的文件。
- 接收前弹窗确认，已信任设备自动接收。
- 文件夹在私有 Staging 中归档，接收端校验后自动还原同名文件夹。
- 接收文件只保存到系统下载目录 `Download/HMTrans`；如果下载目录权限不可用或目录不可写，接收服务不会启动。
- 显示当前传输、历史记录、速度、大小、格式、方向和结果。
- 完成后做 SHA-256 校验。
- 支持暂停、继续、取消、断点恢复、一对多发送和按设备查看历史。
- 底部导航使用 HarmonyOS 6.1 `HdsTabs` 的 `IMMERSIVE + EXQUISITE` 原生材质。
- 支持全屏、分屏、横竖屏与浮窗窗口模式，并提供深色资源。

## 技术要点

- UI：ArkUI。
- 语言：ArkTS。
- 网络：UDP 自动发现 + TCP 文件传输。
- 文件选择：系统 Picker。
- 文件保存：未完成内容放应用私有持久目录，校验成功后发布到 `Download/HMTrans`。
- 校验：SHA-256。

## 当前文件

```text
build-profile.example.json5
hvigorfile.ts
entry/src/main/module.json5
entry/src/main/ets/entryability/EntryAbility.ets
entry/src/main/ets/common/Protocol.ets
entry/src/main/ets/components/       页面组件、原生 HdsTabs Dock 和交互弹层
entry/src/main/ets/controllers/      网络/配对、发送与任务控制器
entry/src/main/ets/persistence/      任务、设备、历史和诊断事件
entry/src/main/ets/services/         发现、传输、目录、归档、后台和诊断服务
entry/src/main/ets/pages/Index.ets
entry/src/main/resources/base/       浅色资源和白屏启动资源
entry/src/main/resources/dark/       深色资源
```

## 构建

首次克隆后，先复制本地构建配置：

```sh
cp build-profile.example.json5 build-profile.json5
```

`build-profile.json5` 可能包含本机签名证书路径和密码，已加入 `.gitignore`，不要提交。

市场发行包（用于上传 AppGallery Connect，不用于 HDC 侧载）：

```sh
cd apps/harmonyos
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \\
  /Applications/DevEco-Studio.app/Contents/tools/node/bin/node \
  /Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/bin/hvigor.js \
  --no-daemon --mode module -p module=entry@default -p product=default assembleHap
```

绑定测试设备的调试包（DevEco Studio 运行前选择 `development` Product）：

```sh
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \\
  /Applications/DevEco-Studio.app/Contents/tools/node/bin/node \
  /Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/bin/hvigor.js \
  --no-daemon --mode module -p module=entry@default -p product=development assembleHap
```

产物：

```text
entry/build/default/outputs/default/entry-default-unsigned.hap
entry/build/default/outputs/default/entry-default-signed.hap
entry/build/development/outputs/default/entry-default-signed.hap
```

真机安装建议直接用 DevEco Studio Run 到 MatePad。

## 安装失败处理

如果 DevEco 安装时报：

```text
Install Failed: error: failed to install bundle.
error: install sign info inconsistent.
```

说明 MatePad 上已经安装过同 bundleName `com.HMTrans.app` 但签名证书不同的版本。应用市场版不能由调试证书直接覆盖，发行证书生成的 `app_gallery` 包也不能通过 HDC 侧载。

- 保留应用市场版：通过 AppGallery Connect 邀请测试、公开测试或正式发布更新。
- 切换到本地调试版：先选择 `development` Product；首次切换需要卸载市场版。`-k` 会请求系统保留用户数据，但切换签名之前仍应备份重要文件。

```sh
hdc shell bm uninstall -n com.HMTrans.app -k
```

然后安装 `entry/build/development/outputs/default/entry-default-signed.hap`。以后只要继续使用 `development` Product，即可直接覆盖调试版。

如果设备上还安装过更名前的旧包，也需要一并卸载；旧包可能继续占用传输端口并把文件保存到旧目录：

```sh
hdc shell bm uninstall -n com.linksc.puresend
```

如果 DevEco 仍然复用旧状态，直接在平板上长按 HM互传 图标卸载一次，然后再用 DevEco Studio Run。

## v0.2 HarmonyOS 实现与待验收

- 使用应用自己的隐私弹窗，同意前不启动局域网服务，不再依赖托管隐私确认流程。
- 把 UDP 发现、TCP 接收和下载目录拆成独立状态，局部失败可见、可重试。
- 使用 relationalStore 按记录增量保存设备、任务/历史和诊断事件，未完成文件及恢复元数据保存在私有持久目录。
- 活动传输使用 `dataTransfer` 后台能力和通知；空闲时不持续长时保活。
- 支持暂停、继续、取消、断点续传、进程重启恢复、文件夹还原和多设备任务。
- 移除每秒轮询和向大量硬编码网段持续广播的空闲高耗电行为。
- 待验收：使用正式签名包和应用市场包完成首次启动、后台、锁屏、浮窗/竖屏、深色模式、三台设备和超大文件测试。

完整范围见：

- `../../docs/01-v0.2产品与交互方案.md`
- `../../docs/02-v0.2技术方案.md`
- `../../docs/03-v0.2传输协议.md`
- `../../docs/04-v0.2开发计划.md`
- `../../docs/05-v0.2验收清单.md`
