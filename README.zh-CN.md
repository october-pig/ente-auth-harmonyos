# Ente Auth for HarmonyOS

[English](README.md) | **简体中文**

使用原生 ArkTS / ArkUI 开发的开源 Ente Auth 鸿蒙移植版。

**非官方社区移植项目，与 Ente 无隶属关系，未经 Ente 背书。**

**当前状态：Alpha / 开发中，版本 v0.1.0-alpha。** 核心流程已实现，但尚未覆盖
官方 Ente Auth 的全部功能，也不应视为生产就绪版本。使用重要账户前，请保留
经过验证的备份与账户恢复信息。

## 应用截图

后续将补充使用合成账户和测试验证码的截图。当前源码不包含真实账户截图。

## 功能与限制

- 原生首页、登录页和设置页面；支持搜索、标签、置顶、回收站和清晰的验证码展示。
- Ente 账户登录与会话管理、在线同步、离线存储及带数据保护的离线到在线迁移。
- TOTP / HOTP、手动添加、二维码扫描，以及部分导入/导出格式。
- 中文和英文资源；部分文本和次级页面仍待完善。设置中的语言和主题项目
  **尚不支持应用内选择**。
- 已有适配系统浅色/深色模式的资源，但仍需完善次级页面的一致性。
- 应用锁/生物识别解锁、passkey 流程、自动本地备份和部分账户/安全设置尚未实现。
  标注为待支持的设置行不代表功能已经启用；“隐藏验证码”也不是应用锁。
- **24 词助记词恢复当前不可用：BIP39 词表尚未完成。** 十六进制恢复路径已存在，
  但缺少完整真机验证。请勿将这个 Alpha 版本作为唯一的账户恢复方式。

详细状态见[功能矩阵](docs/FEATURES.md)与[验证范围](docs/TESTING.md)（英文）。
平板、二合一设备以及其他用户的设备尚无完整验证。

## 使用 DevEco Studio 构建

1. 克隆仓库，在 DevEco Studio 中打开项目根目录。
2. 使用支持 **HarmonyOS SDK 26 / Hvigor 26.0.0** 的 DevEco Studio，安装 HarmonyOS
   SDK 和原生 C/C++ 工具链。应用兼容版本为 **HarmonyOS 6.1.0 / API 23**，
   目标 SDK 为 **26.0.0**。
3. 同步项目并安装 ohpm 依赖。仓库提供依赖锁文件；构建所需的 libsodium
   源码已随项目提供，无需另行下载。
4. 选择 `default` 产品，构建 `entry` 模块。原生库包含 `arm64-v8a` 和 `x86_64`
   两种 ABI。
5. 如需在物理设备运行，请在 **File > Project Structure > Project > Signing Configs**
   中配置**自己的**华为开发者签名身份，再通过 DevEco Studio 运行。

仓库有意保持无签名配置，不包含维护者的私钥、密码或调试 Profile。
请勿将自动签名生成的个人配置和签名材料提交到 Git。

完整命令行步骤、SDK/Java 环境设置和官方签名文档见
[构建与签名指南](docs/BUILDING.md)（英文）。

## 项目结构

- `entry/src/main/ets`：原生 ArkUI 页面和组件、账户服务、OTP、加密封装、
  同步与存储适配层。
- `entry/src/main/cpp`：N-API 加密桥接和随项目提供的 libsodium 源码。
- `AppScope` 与模块资源目录：应用声明、图标、中文/英文及主题资源。
- `tools/host-tests`：可在电脑上运行的逻辑回归测试与明确的 HarmonyOS 平台模型。

HUKS 用于保护存储的密钥材料。应用不使用 Flutter 或 WebView 作为界面外壳。
更多设计边界见[架构说明](docs/ARCHITECTURE.md)（英文）。

## 测试

安装 Node.js 24 或更新版本，然后在项目根目录执行：

```sh
npm ci --prefix tools/host-tests
npm test --prefix tools/host-tests
npm run check:arkts --prefix tools/host-tests
```

HOST 测试使用平台模型执行生产逻辑，不能证明真实 HUKS、数据库、相机或 UI
行为。构建通过、测试代码编译通过、HOST 测试通过与真机验收是不同层次的证据。
测试范围及已知缺口见[测试说明](docs/TESTING.md)。

## 上游与许可证

本项目派生自[官方 Ente 仓库](https://github.com/ente-io/ente)，参考版本固定为：

[`3cc9103a3126de07f79a4465cf0b9922903de54b`](https://github.com/ente-io/ente/tree/3cc9103a3126de07f79a4465cf0b9922903de54b)

本项目不会自动跟随上游最新提交。应用保留未经重绘、未加角标的 Ente Auth
原版图标，这不表示官方认可或维护。

项目以 [AGPL-3.0](LICENSE) 发布。第三方组件来源和声明见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。重新分发源码或二进制时，
请保留对应源码、许可证及版权声明。

## 参与贡献与安全

欢迎提交范围清晰、附复现步骤与测试结果的改进，详见
[贡献指南](CONTRIBUTING.md)（英文）。涉及账户、加密、同步或存储清理的修改，
应核对固定上游版本与 HarmonyOS 官方文档，不应为界面便利而改变业务语义。

**本 Alpha 移植版尚未经过独立安全审计。** 请勿在 Issue、截图或补丁中提供
真实 OTP 密钥、二维码内容、恢复密钥、账户导出、会话 token 或签名材料。
报告安全问题前，请阅读[安全说明](SECURITY.md)，避免公开敏感细节。

## 下载与安装

首个预发布版本为 **v0.1.0-alpha**。下载地址和校验和见
[GitHub Release](https://github.com/october-pig/ente-auth-harmonyos/releases/tag/v0.1.0-alpha)。

- `ente-auth-harmonyos-v0.1.0-alpha-unsigned.hap`：供开发者和测试者使用的
  **无签名构建产物，不能直接安装到任意鸿蒙真机**。
- `SHA256SUMS.txt`：该 HAP 的 SHA-256 校验和。
- GitHub 自动提供对应标签的源码 ZIP 和 tar.gz。

真机测试请使用自己的华为开发者身份，通过 DevEco Studio 或华为官方支持的
流程构建和签名。调试签名受 Profile 中登记设备的限制，维护者设备可安装
不代表其他设备也可安装。

本项目不承诺通用侧载能力、所有鸿蒙设备兼容性或已上架应用市场。
更多限制见[发布说明](docs/RELEASE_NOTES.md)（英文）。
