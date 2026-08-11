# Implementation Plan

1. 修复受管登录：独立配置、凭据等待、身份验证、原子落库和即时发布。
2. 验证 CodexBarCLI 的 JSON 合同并作为 Release helper 打包。
3. 建立 Dashboard 模型、账号级缓存与数据聚合 Store。
4. 实现 SwiftUI 菜单卡、进度条、KPI、柱状图和缺失数据状态。
5. 接入菜单、账号切换和刷新生命周期。
6. 完成测试、许可记录、Release 打包与真实运行验证。

## Risks

- Codex CLI 登录行为变化：以凭据文件和身份读取为完成条件，不只相信退出码。
- CodexBarCLI JSON 变化：固定提交并用 fixture/解码测试锁定合同。
- 本机历史无法按账号归属：明确标注设备级估算，不做虚假拆分。
- 自定义菜单视图影响点击：保持原生 `NSStatusItem.menu`，仅首个菜单项使用托管视图。

## 2026-08-11 — 订阅周期与交互图表修复

详细规格见 `tasks/subscription-chart-fix-spec.md`。

1. 新增本地 ID Token 订阅元数据 reader，并用合成 JWT 锁定字段、日期和状态语义。
2. 将认证监控拆分为账号变化与同账号令牌轮换，避免不必要地清空成功额度。
3. 切换离开当前账号前把实时凭据安全同步回受管副本，再执行目标账号原子切换和验证。
4. 将账号级订阅元数据接入 Dashboard 和原生账号菜单，保持 300pt 紧凑布局。
5. 为 30 天图表增加统一命中层、hover tooltip、点击固定和零值柱支持。
6. 完成竞态、失败保留、菜单尺寸、打包签名和安装后运行验证。

### Dependency Order

`订阅 reader` → `认证变化分类` → `账号同步` → `Dashboard/Menu` → `图表交互` → `Release 验收`

### Key Decision

首版只使用本地 ID Token claim 和现有 QuotaSnapshot 兼容字段；Cockpit 使用的未公开接口不进入主路径。
