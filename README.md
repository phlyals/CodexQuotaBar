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
- **订阅有效期**：只读查询当前账号的 ChatGPT 订阅接口，统一显示核验日期和来源；接口失败会给出原因，登录记录不冒充实时账单、首次购买或自动续费日期。
- **多账号切换**：保存多个 Codex 账号，切换时同步 live 凭据、取消旧刷新任务并校验目标账号。
- **本机用量图表**：查看最近 30 天的 Token 和估算费用，支持悬停详情、点击固定和再次点击取消。
- **账号用量记录**：分别显示账号周额度；Token 和 API 等价费用直接复用 CodexBarCLI 日汇总，本机用量只显示一次，不按额度百分比放大。
- **启动体验**：支持开机自启动、原生 App 图标和紧凑的菜单栏面板。
- **全部留在菜单栏**：保留额度、图表、积分与直接展开的账号列表；规划、消息、订阅和设置使用 300pt 原生子菜单，不打开独立详情窗口。
- **重置券**：积分余额与重置次数分开，券明细显示适用窗口和完整到期时间；不在应用中兑换。
- **用量预算**：双窗口近期钟表时间消耗区间，预留额度、计划时长、正常重置与公告情景分开计算。样本不足不预测。
- **可选提醒**：低额度、券临期、额度恢复和新重置消息；默认关闭，支持夜间静默、24 小时内的延迟消息补提醒和跨启动去重。
- **公开重置消息**：可选每 10 分钟读取 @thsottiaux 的重置 RSS 线索，并核验 X 公开嵌入内容。第三方正文不冒充原帖核验结果。
- **本地优先**：不包含遥测、广告或账号服务器，额度和登录状态只在本机处理。

## 支持范围

- macOS 14 或更高版本
- Apple Silicon Mac（arm64，M1/M2/M3/M4 等）
- Codex Desktop、Codex CLI 或 Codex IDE 扩展产生的本机登录状态

当前构建没有提供 Intel Mac（x86_64）版本。

## 安装

打开 [Releases](https://github.com/phlyals/CodexQuotaBar/releases)，下载最新的 macOS arm64 应用包，
解压后将 `codex额度显示器.app` 拖入“应用程序”文件夹，再打开应用。

本地 0.3.7 构建另提供 `dist/CodexQuotaBar-0.3.7-macOS-arm64.dmg`：打开磁盘映像后，将应用拖到
Applications。该版本目前完成本机验证，尚未上传为 GitHub Release；已通过与未执行的测试见
[菜单精简验收](tasks/compact-menu-acceptance.md)、[订阅与补提醒修复记录](tasks/subscription-reminder-acceptance.md)、[菜单空白修复记录](tasks/menu-blank-fix-acceptance.md)。

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

应用不把账号加入时间冒充首次购买时间。JWT 内的旧订阅声明可能滞后于真实续订；即使登录令牌新签发，
旧日期也不会因此变成已核实。没有可信来源时显示“记录有效至 / 待核验”，不据此发送会员到期警报。

本机 Token/费用是本机全部账号会话日志的汇总，不是当前选中账号的订阅账单。独立每 120 秒扫描，
打开菜单时超过 60 秒则尝试更新；今日按本地自然日匹配，图表保留连续 30 天。价格缺失时标明部分估算。

账号用量页采用同一份 CodexBarCLI 输出，按当前周额度所在日期汇总，明确显示起止日期。
上游输出仅精确到自然日，因此包含重置首日全天，不冒充从重置时刻开始的精确账号账单。
不再运行独立请求配对扫描，也不使用局部额度变化比例推算整周 Token 或补齐未知模型价格。

## 重置消息与用量规划

主菜单保留原来的展开账号列表；“用量规划”“重置消息”“订阅与重置券”“账号用量记录”“设置”均可直接展开，取消“更多信息”中间层。提醒开关显示授权进度；被拒绝时可打开系统通知设置，返回后重新勾选。启用消息订阅后，请求
[Codex Reset Tracker 公开 RSS](https://codexreset.vercel.app/api/feed/codex)，并最多核验每批 3 条 X 原帖。
第三方源不保证完整、即时或长期可用；读取失败退避且保留旧证据，不影响官方额度刷新。
不采用该站的重置概率和历史周期预测，不发送 Codex 凭据或本地用量。也支持主动点击“从剪贴板核验原帖”导入指定作者的帖子链接；不会后台读取剪贴板。

无时区的“今天午夜”仅显示明确标注时区假设的情景；所有相对日期基于发帖时间，不基于抓取日期。
发放完成的消息不会直接把本账号额度填为 100%，需要用后续额度采样核对。

规划需要同账号、同窗口、同周期至少 6 个有效采样，覆盖 15 分钟且有 2 次消耗变化。
只计算近期钟表时间平均消耗，不声称测得活跃使用时间，也不保证剩余可用时长。默认预留 10%。
不开启自动任务、不切换账号、不购买积分、不兑换重置券。

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
额度缓存和本机用量数据都留在当前 Mac 上。额度请求连接 Codex/OpenAI；用量定价来自 CodexBar 的价格数据。
可选公开消息读取会连接上述 RSS 和 X 的公开嵌入服务，服务能看到网络地址。诊断导出先预览，默认不含邮箱、账号标识、凭据和本地路径。

详细说明见 [PRIVACY.md](PRIVACY.md)。第三方依赖和许可证说明见 [OPEN_SOURCE_USAGE.md](OPEN_SOURCE_USAGE.md)
与 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 许可证

本项目使用 [MIT License](LICENSE)。

额度读取和本机用量 helper 复用固定提交版本的
[CodexBar](https://github.com/steipete/CodexBar) / `CodexBarCore`，其许可证文本保存在
[`ThirdPartyLicenses/CodexBar-LICENSE.txt`](ThirdPartyLicenses/CodexBar-LICENSE.txt)。

## English summary

CodexQuotaBar is a native macOS menu bar utility for Codex. It shows the 5-hour and weekly quota,
Spark/Credits data, unverified subscription records, account status, and local token usage estimates.
It is Codex-only, Apple-Silicon-only, local-first, and has no telemetry or account backend.

The app reads the local Codex `auth.json`, supports multiple file-backed accounts, detects same-account
token rotation, and keeps old refresh results from overwriting the active account. The chart supports
hover details and click-to-pin tooltips.

Version 0.3 adds account-isolated history, reset-credit expiration details, optional native notifications,
public reset RSS monitoring, and conservative dual-window usage planning. Announcements never overwrite actual quota.
Version 0.3.3 adds direct subscription and account-history menu entries and fixes notification checkbox interaction during menu tracking, with explicit authorization feedback. It retains the 0.3.2 blank-menu fix and introduces no separate details window.

See the Chinese sections above for installation, credential storage requirements, privacy boundaries,
build commands, and licensing details.
