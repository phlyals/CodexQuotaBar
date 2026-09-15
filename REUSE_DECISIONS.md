# Reuse Decisions

Record dated evidence for reuse, adaptation, rejection, and build-from-scratch decisions.

## 2026-08-02 — Initial record

- Requirement and constraints: keep the existing native macOS quota viewer, make it Codex-only, and switch
  displayed quota together with the actual file-backed Codex Desktop/CLI system account.
- Search sources and queries: local SwiftPM inventory; CodexBar source/releases; official Codex authentication
  manual; GitHub checks for `codex-profiles` and `codex-switcher`.
- Candidates and versions: existing CodexBarCore pin `3f3e2f4`; CodexBar upstream `41bc014` checked on
  2026-08-02; codex-profiles; codex-switcher.
- Validation commands and results: latest upstream promotion planning/execution/service tests passed 35/35 in
  an isolated clone; QuotaFloat uses `swift test`, `swift run QuotaFloat --self-test`, and packaged-app checks.
- Selected strategy: keep the current Core pin, build a QuotaFloat-owned thin adapter, and bundle the pinned
  `CodexBarCLI` executable only as a local usage-scanning helper; do not embed or run the full CodexBar app.
- Reused components: `UsageFetcher`, `CodexHomeScope`, `CodexAuthFingerprint`, account identity and
  `FileManagedCodexAccountStore`.
- Custom components: Codex login runner, QuotaFloat-specific home paths, safe live-account preservation,
  atomic system auth replacement, dashboard UI, helper JSON adapter, quota refresh and optional Codex restart
  prompt.
- Reasons other candidates were rejected: codex-profiles cannot switch an already open Desktop window;
  codex-switcher adds Bun and a duplicate account registry; full CodexBar application reuse is too broad.
- License and security conclusion: MIT-compatible; upstream license retained. Auth files use `0600`, managed
  directories use `0700`, tokens are not logged, keyring-only mode fails closed, and real credentials are not
  used in automated tests.
- Unverified items: OpenAI does not document hot reload of externally replaced auth for an already-running
  Codex Desktop process, so the app offers an explicit restart instead of claiming live reload.
- Reassessment triggers: Codex changes credential format/storage defaults, CodexBar exports promotion as a
  library API, or upstream account tests fail after a dependency update.

## 2026-08-03 — Reliable Codex desktop restart

- Requirement and constraints: after switching the live Codex account, reliably close and reopen the macOS
  Codex desktop app without adding a runtime or third-party dependency.
- Search sources and queries: existing restart implementation; local macOS SDK headers for
  `NSRunningApplication.terminate`, `isTerminated`, `forceTerminate`, and
  `NSWorkspace.OpenConfiguration.createsNewApplicationInstance`.
- Candidates: extend the existing AppKit APIs; invoke `/usr/bin/open`; launch the app executable directly.
- Validation: local SDK documentation confirms termination is asynchronous and must be observed; four fake
  process tests cover slow exit, forced exit, terminal timeout, and launch failure.
- Selected strategy: reuse AppKit, wait up to 10 seconds for normal exit, force termination only after the
  user-approved warning, wait another 5 seconds, then request a new non-substituted application instance.
- Rejected alternatives: `/usr/bin/open` provides weaker typed error handling; direct executable launch
  bypasses LaunchServices application semantics.
- License and security conclusion: Apple system frameworks only; no new dependency, license notice, network
  permission, credential access, or data collection.
- Reassessment triggers: the Codex bundle identifier changes or macOS changes LaunchServices restart
  behavior.
# 2026-09-13 可靠性与规划增量

- 复用固定 CodexBarCore/CLI、Swift Charts、Foundation URLSession/JSONDecoder、AppKit 和 UserNotifications；使用现有协议注入模式和测试框架。无新 Swift 包。
- 业务定制仅包括账号作用域校验、来源可信度、采样预测、消息事件归并与中文呈现，不复制依赖扫描器或定价表。
- UserNotifications 采用 Apple 原生授权/通知 API，避免第三方通知 SDK 与额外数据发送。
- X 官方用户时间线 GET /2/users/:id/tweets 需要开发者 Bearer Token。不能把公开嵌入接口当成有保证的完整时间线；公共聚合源只能作为可选线索，仍需作者和帖子 ID 校验，失败必须降级。
- 不沿用公开重置网站根据历史间隔输出的概率/睡眠时间预测；此类推测缺少可验证精度，不适用于实际账号用量规划。
- 来源核验：https://docs.x.com/x-api/posts/timelines/introduction ，https://developer.apple.com/documentation/UserNotifications/scheduling-a-notification-locally-from-your-app 。
# 2026-09-13 公开消息接入结论

- 采用公开 RSS `https://codexreset.vercel.app/api/feed/codex`，网站主动提供订阅入口；实读 HTTP 200。
- 使用系统 XMLParser，禁用外部实体解析，限制响应体 1 MB，不依赖网页 DOM 或第三方分类结果。
- 原帖核验使用 X 公开嵌入响应。长文可能截断，因此 RSS 正文仍标第三方线索。
- 不复制第三方站点源码，不采纳其概率模型；RSS 不是官方时间线完整性保证，默认可关闭、失败退避。
- 无新增第三方 Swift 包；沿用 CodexBar MIT 固定版本、Swift Charts 和 macOS UserNotifications。

## 2026-09-14 周期 Token 账单

- CodexBarCLI 公开输出为按天、全机器汇总，不能作为单账号单轮账单；保留原仪表盘用途。
- 新增只读请求元数据扫描，用 Foundation JSONSerialization / FileHandle，不复制上游内部扫描器。仅接收有 response_id 且能与紧邻额度事件对应的请求；旧格式和无法匹配的记录不推断计入。
- 复用现有 CodexBar models.dev 价格缓存，精确匹配模型，不新增网络服务、API 密钥或硬编码价格。缓存输入从总输入拆分，输出不重复加入 reasoning token。未知价格、超过 200K 输入的分档请求暂不估价；部分费用显式标注。
- 窗口重置时刻只能推断账号归属，界面标注“本机窗口匹配”；多个账号共享相同窗口时不分配。请求 ID 跨文件去重，有冲突时排除。
- 扫描在独立 actor 中，最多每分钟检查一次，未变文件复用内存结果，价格缓存变化触发重新计算。不保存对话正文，不新增磁盘账单或上传数据。

## 2026-09-14 简化本周估算

- 复用已存在的账号作用域、请求去重、额度周期和模型定价；不增加依赖或联网能力。
- 页面改为每账号一份本周已用账单。以本轮观测消耗对应的 Token / 美元比例，推算当前已用额度总量，始终注明估算，不再只展示部分区间账单。
- 部分区间不足两个百分点时等待记录；费用缺失只能用同模型、本轮已定价请求的平均 Token 成本补估。无同模型依据时显示费用待估，不能把已知部分价格当成总金额。
- 比率校准截至最后一次日志扫描边界，避免新额度采样摊薄旧 Token 汇总；检测重置后不会拿上一轮比率推新一轮。
- 估算假定本机已记录请求具有代表性，模型、上下文、缓存比例及跨设备用量会影响准确度。这里只是 Token 价值估算，不是订阅账单。

## 2026-09-15 直接复用 CodexBar 用量统计

- 用户选择保留现有应用并复用 CodexBar。沿用已固定的 CodexBarCore / CodexBarCLI revision `3f3e2f4a112aa504c493ad5636c94e45df85fd03` 和 MIT 分发声明；没有整体升级依赖，也没有引入 ccusage / Tokscale。
- 账号用量页与主仪表盘共用 `CodexDashboardStore.localUsage`；仅按日期筛选、相加上游 Token / cost 字段，不自建价格表或解析日志。取消 `QuotaAssistantModel` 中的独立账单扫描调度，旧配对器和比例估算不再参与生产界面。
- 上游接口为按日本机汇总。页面显示一次本机总量、起止日期与首日全天说明，账号仅展示官方额度，避免把共享日志错误分配到每个账号。该值不是精确到重置秒的账号周期账单。
- 价格缺失不做同模型均价填充；部分日费用保留部分标记。过期周期、扫描早于周期、缺失报告不冒充零用量。沿用上游当前固定版本的解析与定价局限，不声称已包含上游 main 的全部修复。
