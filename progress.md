# Progress

## 2026-08-02

- 已确认用户授权修复。
- 已完成运行时根因检查和 CodexBar 本地依赖对照。
- 开始实施原生状态栏按钮渲染方案。
- 已移除覆盖在按钮上的 `StatusBarQuotaView`，改为离屏渲染后赋给原生按钮图片。
- 已增加 64×22 非零高度图片的回归测试。
- `swift format lint --strict` 通过。
- `swift test` 通过：16 个 XCTest + 2 个 Swift Testing 测试。
- `swift run QuotaFloat --self-test` 通过。
- Release 应用重新打包并通过 arm64、ad-hoc 签名验证。
- 修复版已重启，当前仅一个 0.2.0 实例。
- 运行时 `NSStatusBarButton` 已由 `64×0` 恢复为 `64×22`，且无覆盖子视图、无错误日志。
- Computer Use 无法从无普通窗口的 accessory app 读取弹出菜单，等待用户做最终单击确认。
- 用户确认菜单点击正常。
- 将离屏渲染的两行额度文字由动态 `.labelColor` 改为明确白色。
- 增加文字区域白色像素回归断言；完整测试、自检、Release 打包和签名再次通过。
- 白色文字修复版已重启，当前 PID 22712，只有一个实例。

## 2026-08-02 — 多账号与详情面板

- 用户确认实施账号添加修复与 CodexBar 风格详情面板。
- 已将确认过的假设、边界、成功标准写入 `tasks/codex-dashboard-spec.md`。
- 已建立实施计划和任务清单，开始修复受管账号登录。
- 已实现受管登录目录的文件凭据配置、登录后凭据等待和身份验证。
- 已加入可注入登录 runner，新增账号成功落库/即时发布与安全配置测试；6 个账号管理测试通过。
- 已开始构建固定提交的 CodexBarCLI，验证本机费用 JSON 合同。
- 已接入 CodexBarCLI 本机 Token/费用读取，使用隔离配置避免已安装 CodexBar 的旧配置干扰。
- 已实现 CodexBar 风格详情面板：账号/套餐、5 小时和每周额度、重置时间、今日与 30 天 Token/估算费用、30 天图表、常用模型与重置额度。
- 已将“根据本机 Token 用量估算，不是订阅账单”直接显示在面板中。
- 完整测试通过：20 个 XCTest + 2 个 Swift Testing 测试；严格格式检查和 self-test 通过。
- Release 已包含 arm64 CodexBarCLI helper，并通过 deep codesign、helper 真实数据 smoke test。
- 新版应用已重启，当前只有一个运行实例（PID 25855）。

## 2026-08-06 — 方案阶段

- 用户要求先说明处理方案，暂不修改源码。
- 已完成账号登录/切换调用链和 CodexBar 上游实现对照。
- 已确认最高优先级是修复 `QuotaStore` 切换时不取消旧 in-flight 请求的竞态，其次是登录 runner 的 Pipe 排空和身份确认。
- 已规划 CodexBar 风格详情面板扩展、账号级状态隔离、专项测试和 Release 验收。

## 2026-08-06 — 修复完成

- 登录 runner 已改为持续排空 stdout/stderr，支持有效 PATH 下的 Codex CLI 发现，并在超时时清理整个进程组。
- 账号切换已加入旧任务取消、原子替换、目标邮箱/指纹校验和失败回滚；切换失败不会污染当前账号或保存列表。
- 额度与本机用量刷新均加入 token 隔离，旧账号请求晚返回时不会覆盖新账号状态。
- 详情面板已扩展为 CodexBar 风格的 Codex 账户、套餐、5 小时/每周/Spark 额度、Token 估算和趋势图布局。
- 严格格式检查、`swift test --parallel`（22 个 XCTest + 2 个 Swift Testing）、`QuotaFloat --self-test` 均通过。
- Release `.app` 已构建为 arm64，通过 Info.plist、deep codesign 和安装后启动验证；当前 `/Applications/codex额度显示器.app` 只有一个运行实例。

## 2026-08-07 — Codex-only 面板对齐

- 已对照 CodexBar 当前发布内容，确认重点是 Codex 额度窗口、Credits、本机用量图表和多账号菜单；界面不再需要其他平台入口。
- 已移除详情面板顶部的 Overview/Claude/Gemini 标签，固定为 Codex 账号头部。
- 每周、5 小时、Codex Spark Weekly 三个额度窗口现在始终按截图顺序展示；数据缺失时显示占位和“重置时间未知”，不再隐藏 5 小时行。
- 用量仪表盘改为截图相同的两列指标、柱状图、最常用模型和本机估算说明；额外额度改为独立一行。
- 菜单中移除旧平台凭据清理入口，保留 Codex 账号列表、添加、移除、刷新、开机自启动和退出。
- `swift format lint --recursive --strict Sources Tests`、`swift test --parallel`（22 个 XCTest + 2 个 Swift Testing）、源码与安装包 self-test 全部通过。
- 新版 arm64 应用已安装到 `/Applications/codex额度显示器.app` 并启动，安装包与 `dist` 包内可执行文件校验和一致。

## 2026-08-07 — Credits 语义修复完成

- 根因确认：旧实现把 Codex `CreditsSnapshot.remaining` 关闭在 `includeCredits: false`，同时把 `resetCredits.availableCount` 当成唯一“额度”展示。
- 已接入真实 `result.credits`，并保留 `creditsRemaining`、`creditsUpdatedAt` 与 `resetCredits` 的独立字段；数值型 Credits 和次数型重置额度不再互相冒充。
- 已修正 Spark 映射：`Codex Spark 5-hour` 与 `Codex Spark Weekly` 分别进入对应窗口，不再取第一个 Spark 项目硬塞到周额度。
- 当 Credits 存在时，面板显示 CodexBar 风格的“额度”进度条、余额和 `1K token` 标尺；没有 numeric Credits 时显示“额外额度”次数或占位。
- 实际安装运行后缓存已验证：当前 OAuth 返回非零 numeric Credits、重置额度 `0`、周额度和 Spark 周额度均来自真实响应；没有输出任何凭据内容。
- 新增 2 个额度映射测试；完整 `swift test --parallel` 通过（24 个 XCTest + 2 个 Swift Testing），严格格式检查、自检、arm64 打包、签名和安装后单实例启动通过。

## 2026-08-07 — 菜单紧凑度修复完成

- 对照 CodexBar `UsageMenuCardLayout`：使用 `body/subheadline/footnote` 字体层级、约 6–7pt 区块留白和更短的图表/进度条。
- Codex 详情卡横向内边距调整为 20pt，菜单承载高度由 570pt 降为 500pt，避免自定义 NSMenu 行额外撑大页面。
- 账号头部、额度窗口、用量指标、图表和 Credits 行均完成紧凑化；宽度保持 330pt，保证邮箱和重置文本不被截断。
- 严格格式检查、24 个 XCTest + 2 个 Swift Testing、自检、arm64 打包、deep codesign、安装后启动和单实例验证全部通过。

## 2026-08-07 — 账号购买与到期日期

- 复核后确认：Codex OAuth/CLI 当前实际返回套餐类型、额度窗口和 Credits，不返回购买日期或合同到期日期；账号加入时间和额度重置时间都不能冒充购买/到期时间。
- 已移除手工日期备注、日期文件和编辑入口，避免应用显示用户自己填写的伪“自动数据”。
- `QuotaSnapshot` 现在保留真实 `subscriptionExpiresAt / subscriptionRenewsAt` 字段；如果上游将来对 Codex 返回这些字段，面板会自动显示“到期/续费”，没有数据时不额外占位。
- 面板进一步压缩为 300pt 宽、较小字号、较短图表和更紧凑间距，保持额度信息清晰可扫读。

## 2026-08-11 — 详细修复方案

- 按用户要求仅做代码审阅和方案设计，没有修改业务源码。
- 确认当前 ID Token 为每个已保存账号提供本期开始、有效至和最后核验字段；语义限定为当前订阅周期，不称为首次购买时间。
- 确认现有图表只有静态 `BarMark`，每日数据已经足够支持日期、Token、预估费用和主要模型 tooltip。
- 发现同账号 token 轮换目前被 Auth monitor 有意忽略，且当前账号刷新后的 live 凭据没有稳定回写已存在的受管副本；两者已纳入账号同步修复范围。
- 已写入完整规格 `tasks/subscription-chart-fix-spec.md`，并更新实施计划和未完成任务清单。

## 2026-08-11 — 修复、打包与重启完成

- 已实现 JWT 订阅周期读取：显示当前周期开始/有效至、最后核验时间、剩余天数和过期状态；没有可靠字段时明确显示未知，不把加入时间冒充购买时间。
- 已区分账号切换与同账号 Token 轮换；当前 live 凭据会原子同步到已有受管账号目录，避免切换账号后仍使用旧 Token 或长期显示旧额度。
- 已将周期信息接入顶部账户区域和账号菜单，菜单高度改为按内容自适应并限制在紧凑尺寸内。
- 已为 30 天柱状图加入 hover tooltip、点击固定/再次点击取消、零值柱命中和不改变布局的详情浮层。
- `swift format lint --recursive --strict Sources Tests` 通过；`swift test --parallel` 通过，共 33 个测试；`QuotaFloat --self-test` 通过。
- Release arm64 应用已重新打包、通过 deep codesign，安装到 `/Applications/codex额度显示器.app`；安装后自检和签名校验通过。
- 应用已重新启动，当前只有一个运行中的 `QuotaFloat` 实例，版本为 `0.2.0`。
- 追加修复状态栏渲染：改为直接绘制 `NSImage`，真实屏幕已确认 `C` 图标和两行额度文字可见；并将图表 tooltip 改为固定宽度、分行对齐，避免窄菜单下内容挤压。
- tooltip 修复后再次通过严格格式检查、33 个测试、Release 构建、deep codesign、arm64 校验和安装后 self-test；最终实例 PID 为 `85814`。
