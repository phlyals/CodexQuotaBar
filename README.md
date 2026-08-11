# CodexQuotaBar

<p align="center">
  <img src="Resources/AppIcon.png" alt="CodexQuotaBar app icon" width="128">
</p>

<p align="center">
  <strong>codex额度显示器</strong>
</p>

一个原生 macOS 菜单栏工具，在不打开 Codex 窗口的情况下查看 Codex 额度、订阅周期和本机用量。
它只显示 Codex，不包含 Claude、Gemini 或其他平台入口。

[English summary](#english-summary) · [安装](#安装) · [从源码构建](#从源码构建) · [隐私](#隐私与数据边界)

## 功能亮点

- **菜单栏优先**：顶部显示渐变 `C` 图标，以及 5 小时和周额度的简短状态。
- **Codex-only 面板**：显示每周、5 小时、Codex Spark Weekly、Credits 和重置时间。
- **真实数据状态**：区分实时、缓存、过期和登录失效，不用虚假的 `99%` 或 `100%` 填充缺失数据。
- **订阅周期**：从 Codex 登录令牌读取当前周期的开始时间、有效至和核验状态，并显示剩余天数。
- **多账号切换**：保存多个 Codex 账号，切换时同步 live 凭据、取消旧刷新任务并校验目标账号。
- **本机用量图表**：查看最近 30 天的 Token 和估算费用，支持悬停详情、点击固定和再次点击取消。
- **启动体验**：支持开机自启动、原生 App 图标和紧凑的菜单栏面板。
- **本地优先**：不包含遥测、广告或账号服务器，额度和登录状态只在本机处理。

## 支持范围

- macOS 14 或更高版本
- Apple Silicon Mac（arm64，M1/M2/M3/M4 等）
- Codex Desktop、Codex CLI 或 Codex IDE 扩展产生的本机登录状态

当前构建没有提供 Intel Mac（x86_64）版本。

## 安装

打开 [Releases](https://github.com/phlyals/CodexQuotaBar/releases)，下载最新的 macOS arm64 应用包，
解压后将 `codex额度显示器.app` 拖入“应用程序”文件夹，再打开应用。

本项目的公开构建使用 ad-hoc 签名，尚未使用 Apple Developer ID 公证。第一次打开时如果 macOS
提示无法验证开发者：在 Finder 中对应用按住 Control 点击，选择“打开”，然后再次确认；必要时在
“系统设置 → 隐私与安全性”中允许打开。

## 使用前准备

应用读取 Codex 的本机认证缓存：

- 设置了 `CODEX_HOME` 时读取 `$CODEX_HOME/auth.json`
- 否则读取 `~/.codex/auth.json`

Codex Desktop、CLI 或 IDE 扩展只要共享这份登录缓存即可。当前版本不读取只存在于 macOS Keychain
而没有 `auth.json` 的凭据；需要在 Codex 配置中使用文件凭据：

```toml
cli_auth_credentials_store = "file"
```

## 账号与订阅信息

在菜单中选择“添加 Codex 账号…”即可启动隔离的 Codex 登录流程。已保存账号放在本机应用支持目录，
切换时会以安全权限原子替换 live `auth.json`，并刷新额度和本机用量。

应用显示的是 Codex 当前返回的订阅周期，不把账号加入时间冒充首次购买时间。Codex 没有返回购买日期
或合同到期字段时，界面会显示“未知”；这属于数据不可用，而不是手工备注。

本机 Token/费用图表来自本地 Codex 会话日志，是用量估算，不是订阅账单。

## 从源码构建

要求 Swift 6.2+、macOS 14+ 和 Apple Silicon Mac：

```bash
git clone https://github.com/phlyals/CodexQuotaBar.git
cd CodexQuotaBar
swift test --parallel
swift run QuotaFloat --self-test
swift run QuotaFloat
```

构建可分发的本机 arm64 应用：

```bash
./Scripts/package_app.sh
open dist/codex额度显示器.app
```

脚本会构建 QuotaFloat 和本地 CodexBarCLI helper，复制许可证文件，并生成 ad-hoc 签名的
`dist/codex额度显示器.app`。

## 项目结构

```text
Sources/QuotaFloat/
├── CodexBarQuotaFetcher.swift       # Codex 额度与 Credits 映射
├── CodexAccountManager.swift        # 多账号、隔离目录与安全切换
├── CodexAuthMonitor.swift           # 账号变化与 Token 轮换检测
├── CodexSubscriptionMetadata.swift  # 订阅周期与 JWT 元数据读取
├── CodexDashboardView.swift         # Codex-only 菜单面板与图表
└── StatusBarQuotaController.swift   # 菜单栏 C 图标和原生菜单
```

## 隐私与数据边界

CodexQuotaBar 不提供账号系统，不上传凭证、额度或使用数据，也不包含遥测和广告。认证文件、账号副本、
额度缓存和本机用量数据都留在当前 Mac 上。网络请求只用于 Codex/OpenAI 官方额度接口。

详细说明见 [PRIVACY.md](PRIVACY.md)。第三方依赖和许可证说明见 [OPEN_SOURCE_USAGE.md](OPEN_SOURCE_USAGE.md)
与 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 许可证

本项目使用 [MIT License](LICENSE)。

额度读取和本机用量 helper 复用固定提交版本的
[CodexBar](https://github.com/steipete/CodexBar) / `CodexBarCore`，其许可证文本保存在
[`ThirdPartyLicenses/CodexBar-LICENSE.txt`](ThirdPartyLicenses/CodexBar-LICENSE.txt)。

## English summary

CodexQuotaBar is a native macOS menu bar utility for Codex. It shows the 5-hour and weekly quota,
Spark/Credits data, the current subscription period, account status, and local token usage estimates.
It is Codex-only, Apple-Silicon-only, local-first, and has no telemetry or account backend.

The app reads the local Codex `auth.json`, supports multiple file-backed accounts, detects same-account
token rotation, and keeps old refresh results from overwriting the active account. The chart supports
hover details and click-to-pin tooltips.

See the Chinese sections above for installation, credential storage requirements, privacy boundaries,
build commands, and licensing details.
