# Spec: Codex 多账号与详细额度面板

## Objective

修复“浏览器登录成功但账号没有加入列表”，并让菜单栏弹出内容接近 CodexBar：显示账号、套餐、更新时间、额度、重置时间、本机 Token/费用估算、30 天趋势、常用模型和 Credits。

### 已确认假设

1. 新账号在独立的受管 `CODEX_HOME` 中登录并保存，添加成功后立即进入账号列表，但不会静默替换系统当前账号。
2. 用户点击账号时，系统 Codex 登录与该账号额度一起切换。
3. 额度、邮箱和套餐是账号级在线数据；Token/费用来自本机日志，无法可靠归属账号时必须标注“本机估算”，不能宣称是订阅账单。
4. 保留当前两行白色菜单栏图标、macOS 14+、Apple Silicon 和 Codex-only 范围。

## Tech Stack

- Swift 6.2、AppKit、SwiftUI、Swift Charts（系统框架）
- CodexBarCore 固定提交 `3f3e2f4a112aa504c493ad5636c94e45df85fd03`（MIT）
- CodexBarCLI 的 `cost --provider codex --format json` 作为本机用量数据来源；作为受控 helper 随应用打包，不复制其扫描器源码
- XCTest / Swift Testing

## Commands

- 格式：`swift format lint --strict Sources Tests`
- 测试：`swift test`
- 自检：`swift run QuotaFloat --self-test`
- 打包：`./Scripts/package_app.sh`
- 启动：`open -n dist/codex额度显示器.app`

## Project Structure

- `Sources/QuotaFloat/CodexAccountManager.swift`：受管账号登录、验证、保存和系统切换
- `Sources/QuotaFloat/CodexDashboardModels.swift`：面板数据和账号级缓存模型
- `Sources/QuotaFloat/CodexDashboardStore.swift`：在线额度与本机用量的聚合/刷新
- `Sources/QuotaFloat/CodexCostHelper.swift`：CodexBarCLI JSON 适配器
- `Sources/QuotaFloat/CodexDashboardView.swift`：SwiftUI 详情卡片和图表
- `Sources/QuotaFloat/StatusBarQuotaController.swift`：菜单托管与账号操作
- `Tests/QuotaFloatTests/`：账号、解析、模型与渲染测试

## Code Style

```swift
struct CodexDashboardSnapshot: Codable, Equatable, Sendable {
  let accountID: String
  let accountEmail: String?
  let quota: QuotaSnapshot
  let localUsage: CodexLocalUsageSnapshot?
}
```

- 类型表达业务含义，不把第三方 JSON 直接传进 UI。
- 所有凭据写入使用 `0600`，受管目录使用 `0700`。
- UI 只订阅主线程 Store；扫描和网络读取在异步任务中执行。

## Testing Strategy

- 单元测试：凭据模式、登录完成判断、账号落库、重复账号更新、成本 JSON 解码、格式化和账号缓存隔离。
- 组件测试：详情面板在完整、部分和无本机日志数据下均可生成。
- 集成验证：两个模拟账号添加/切换；Release helper 存在、可执行、签名有效。
- 真实人工验收：完成一次浏览器登录，账号立即出现；切换后邮箱和额度同步；菜单显示详情卡。

## Boundaries

- Always：原子保存凭据、账号级隔离缓存、清楚标注费用为本机估算、保留 CodexBar 许可。
- Ask first：修改用户全局 Codex 配置、自动重启 Codex、覆盖 `/Applications` 中旧版。
- Never：记录或输出令牌、把本机估算冒充账单、复制未记录来源的第三方源码、恢复 Claude/Kimi。

## Success Criteria

1. 浏览器登录完成后，只有在独立账号目录内凭据和身份验证成功才提示添加成功；账号列表无需重启立即更新。
2. 重复登录同一账号不会产生重复记录；多 Workspace 可区分。
3. 点击账号后，系统 `auth.json` 原子切换，面板先清除旧账号数据，再加载目标账号额度。
4. 面板展示邮箱、套餐、更新时间、每周/5 小时额度、倒计时、今日/30 天 Token 和费用、30 天柱状图、常用模型与 Credits；缺失项显示 `—`。
5. 费用区域显示“根据本机 Token 用量估算，不是订阅账单”。
6. 所有测试、自检、Release 打包、签名和单实例运行验证通过。

## Open Questions

- 无阻塞问题。真实浏览器登录和账号切换在自动测试后由用户做最终验收。
