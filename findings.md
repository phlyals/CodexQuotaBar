# Findings

- 运行中 `NSStatusBarWindow` 为 `80×33`，但 `NSStatusBarButton` frame 为 `64×0`。
- 图标和文字通过自定义子视图溢出绘制，因此可见但无可点击区域。
- 根因是清空原生按钮标题和图片后，只添加不参与按钮固有尺寸计算的覆盖子视图。
- 已固定的 CodexBar 依赖使用原生 `NSStatusBarButton.image` 与 `NSStatusItem.menu`，MIT 许可；本次仅参考其原生状态项架构，不复制源码。
- 首选方案：把现有 64×22 两行内容渲染为模板 `NSImage` 并赋给按钮，菜单继续使用 AppKit 原生机制。
- 用户已确认点击与菜单恢复正常；离屏渲染使动态 `.labelColor` 在浅色 appearance 下解析为黑色，需要为菜单栏位图明确使用白色文字。
- 账号添加原实现与 CodexBar 的基本受管目录流程接近，但没有在新目录显式要求文件凭据，也只在进程退出后读取一次身份；浏览器成功而凭据延迟/落入钥匙串时会无法落库。
- 修复路径：在独立目录写入 `cli_auth_credentials_store = "file"`，登录成功后等待 `auth.json` 与可解析邮箱，再原子保存并发布账号数组。
- CodexBarCLI 已提供稳定的 `cost --provider codex --format json` 契约，包含今日/30 天 Token、费用、每日条目、模型及模型拆分；直接复用 helper 比复制内部扫描器源码更合适。

## 2026-08-06 — 账号切换稳定性诊断

- `CodexAccountManager` 的登录 runner 将 stdout/stderr 接入一个未持续读取的 `Pipe`，存在输出量较大时子进程阻塞并最终超时的风险；CodexBar 上游已使用独立的持续排空器和进程组清理。
- 新账号登录成功后只等待 10 秒，并要求 `UsageFetcher.loadAuthBackedCodexAccount()` 同时解析出邮箱；这会把凭据已经写入但身份字段暂时不完整的情况判为失败。
- `QuotaStore.invalidateAndRefresh()` 清除快照后，如果旧账号请求仍在进行，不会取消旧任务，也不会立即启动新任务；旧任务完成后仍可写入旧账号结果。这是切换后数据错乱的确定性竞态。
- 当前切换流程在身份验证之后立即触发额度刷新，且 Codex Desktop/CLI 可能仍持有旧状态；需要加入切换代次、取消旧请求、目标身份验证和刷新防抖。
- 当前机器上的托管账号 auth.json 均存在完整 token 字段并为 `0600`；基线测试通过，因此持久化文件损坏暂不是首要原因。

## 2026-08-06 — UI 目标

- 以现有 `CodexDashboardView` 和 CodexBarCore 数据模型为基础扩展，不复制第三方大段源码。
- 页面目标包括顶部 Codex/其他服务切换、账号和套餐信息、5 小时/每周额度条、Spark 或额外额度、今日/30 天 Token 与费用、柱状趋势图、额外额度和底部操作菜单。
- 保留费用“本机 Token 用量估算，不是订阅账单”提示，避免把本机日志统计误认为服务器账单。

## 2026-08-07 — Codex-only UI 复核

- 最新 CodexBar 的核心菜单层级是账号头部、额度窗口、Credits、本机 Token/费用历史、图表和多账号操作；本项目不需要复刻其他平台的入口。
- 原面板仍显示 Claude/Gemini 标签，且 5 小时窗口在缺失时直接不渲染，造成布局和截图不一致。
- 采用只显示 Codex 的轻量头部，固定渲染每周、5 小时和 Spark 三行，并以固定进度条轨道保持缺失数据时的布局稳定。
- 账号列表继续使用原生 NSMenuItem，保证账号切换交互不受 SwiftUI 详情卡改版影响。

## 2026-08-07 — Credits 数据根因

- `CodexBarQuotaFetcher` 原来设置 `includeCredits: false`，所以 OAuth/CLI 返回的 numeric Credits 没有进入 QuotaFloat 数据模型。
- 当前项目只保存 `resetCredits.availableCount`，它代表可用的额度重置次数，不代表 Credits 余额；把它显示成统一“额度”会造成两张截图中的数字不一致。
- CodexBar 的 Credits UI 使用 `CreditsSnapshot.remaining`，并以 1000 token 作为显示标尺；本项目已按同一语义接入，但仍保持 Codex-only。
- `UsageSnapshot.extraRateWindows` 可能同时返回 Spark 5 小时和 Spark 周窗口；必须按稳定 id/title 和窗口时长映射，不能依赖数组顺序。

## 2026-08-07 — 菜单尺寸复核

- 当前页面偏大的主要来源不是菜单栏字体，而是 SwiftUI 详情卡使用了 `title2/title3/headline` 和较大的区块 padding，同时 NSMenu 自定义承载行固定为 570pt。
- CodexBar 的菜单卡以 `headline` 作为主标题、`subheadline/footnote` 作为详情，并将各段 padding 控制在约 6–7pt；已按该密度收敛。
- 菜单宽度暂时保持 330pt，先缩小视觉层级和高度，避免同时改变文本可用宽度导致邮箱/重置时间重新换行。

## 2026-08-07 — 账号订阅日期

- Codex OAuth `wham/usage` 当前可解析字段是 `plan_type`、`rate_limit`、`additional_rate_limits` 和 `credits`，不包含购买日期或合同到期日期。
- CodexBar 的通用 `subscriptionExpiresAt / subscriptionRenewsAt` 字段主要服务其他可提供订阅元数据的 provider；当前 Codex 路径没有填充它们。
- 运行中 QuotaFloat OAuth 缓存实际只有套餐、额度窗口、Credits 和重置信息，未出现购买/到期字段。
- 已撤销手工日期存储方案；只保留真实字段的前向兼容映射，缺失时不显示空白日期行。

## 2026-08-11 — 订阅周期与图表交互方案复核

- 当前机器的 Codex `id_token` 在 namespaced claim 中提供 `chatgpt_subscription_active_start`、`chatgpt_subscription_active_until` 和 `chatgpt_subscription_last_checked`；已保存的 4 个受管账号均存在这些字段。它们可用于自动显示“本期开始/有效至”，但 `active_start` 不能表述为历史首次购买时间。
- `CodexManagedAccountViewModel` 目前只有邮箱、Workspace 和当前账号标记；需要增加账号级订阅元数据，数据必须从每个 `managedHomePath/auth.json` 独立读取，不能依赖当前系统账号的全局状态。
- `QuotaSnapshot` 已有 `subscriptionExpiresAt` 和 `subscriptionRenewsAt`，但缺少周期开始、最后核验、来源与状态字段；CodexBar 当前 Codex fetch 路径也不会填充通用订阅日期。
- 现有 `QuotaStore` 和 `CodexDashboardStore` 已使用任务取消与 UUID token 拒绝迟到结果；新增订阅刷新应复用同一代次隔离，不重写已有账号切换事务。
- 当前 `CodexDashboardView` 的 30 天图表只有静态 `BarMark`，没有 hover、点击、选中状态或 chart overlay，所以鼠标停留与点击都不会产生反馈。
- `CodexLocalUsageSnapshot.DailyEntry` 已包含日期、总 Token、估算费用、模型和模型拆分，足以支持 tooltip，无需改变 CodexBarCLI JSON 合同。
- 账号菜单目前使用普通 `NSMenuItem.title`；适合保持单行原生菜单，通过中间截断邮箱、右侧短日期和 tooltip 呈现完整周期，避免把每个账号扩成多行自定义卡片。
