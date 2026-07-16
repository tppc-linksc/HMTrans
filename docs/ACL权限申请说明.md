# HM互传 ACL 权限申请说明

## 需要申请的权限

- 权限名：`ohos.permission.READ_LOCAL_DEVICE_NAME`
- 权限类型：`system_basic`、`system_grant`
- 用途：读取 HarmonyOS“设置 > 关于本机”中由用户设置的设备显示名称。
- 未获权限时的系统行为：设备管理接口只返回出厂默认名称，例如 `MatePad Pro`，不会返回 `Linksc的MatePad Pro`。

## AGC 申请路径

1. 登录 AppGallery Connect（AGC），进入 HM互传 对应项目与应用。
2. 进入“开发与服务 > 项目设置 > ACL 权限申请”。
3. 搜索并选择 `ohos.permission.READ_LOCAL_DEVICE_NAME`。
4. 如页面提供“5 天 ACL 试用权限”，可先开启试用并生成临时调试 Profile，用于真机验证。
5. 同时提交正式申请；获批后为调试和发布分别生成包含该 ACL 的 Profile。

## 建议填写的申请说明

> HM互传是一款由用户主动操作的 Mac 与 HarmonyOS 平板局域网文件互传工具。用户在两端看到附近设备后，通过六位配对码确认连接。应用需要读取“关于本机”中的设备显示名称并展示在对方 Mac 上，帮助用户准确识别正在配对和接收文件的物理设备，避免同型号设备之间误连。设备名称仅随局域网发现包发送给同一局域网内运行 HM互传 的设备，不上传云端、不用于广告、账号画像或跨应用跟踪。用户可通过关闭自动发现或卸载应用停止处理。

建议一并提交以下材料：

- Pad“关于本机”显示 `Linksc的MatePad Pro` 的截图。
- Mac 端未获权限时只能显示 `MatePad Pro` 的截图。
- 双端六位配对码与附近设备页面截图。
- 隐私政策链接：`https://hmt.tppc.top/privacy.html`。

## 获批后的签名配置

1. 在 DevEco Studio 登录与 AGC 应用一致的华为开发者账号。
2. 打开“File > Project Structure > Signing Configs”，为当前产品重新生成或下载调试签名 Profile。
3. 发布包使用 AGC 生成的发布 Profile；不要继续使用申请前的旧 Profile。
4. 将项目 `build-profile.json5` 中签名配置的 `profile` 路径更新为新 `.p7b` 文件路径；证书和私钥必须与该 Profile 配套。
5. 确认新 Profile 的 `acls.allowed-acls` 中包含 `ohos.permission.READ_LOCAL_DEVICE_NAME`，再重新构建、安装和提交应用市场。

可在 macOS 终端检查 Profile：

```bash
openssl smime -inform DER -verify -noverify -in /path/to/profile.p7b 2>/dev/null \
  | grep -o '"allowed-acls":\[[^]]*\]'
```

预期输出中同时包含：

```text
ohos.permission.READ_LOCAL_DEVICE_NAME
```

如果清单已声明该权限，但签名 Profile 未包含该 ACL，真机安装会失败；不同安装入口可能提示 `install sign info inconsistent`，或提示 `grant request permissions failed (9568289)`。这时不需要回退代码，只需要换成获批后重新生成的 Profile 再构建。
