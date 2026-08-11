# Tasks

- [x] Task 1：修复受管账号添加
  - Acceptance：登录凭据验证后原子落库并即时显示；同账号更新而不重复。
  - Verify：账号管理 XCTest。
  - Files：`CodexAccountManager.swift`、对应测试。
- [x] Task 2：接入 CodexBarCLI helper
  - Acceptance：能解码 codex cost JSON；Release 包含已签名可执行 helper。
  - Verify：fixture 测试、helper smoke test。
  - Files：`CodexCostHelper.swift`、打包脚本、测试、许可记录。
- [x] Task 3：Dashboard 数据层
  - Acceptance：当前账号额度与设备本机用量聚合；本机估算明确不声明为账号账单。
  - Verify：模型、缓存、Store 测试。
  - Files：Dashboard models/store、Quota model/fetcher、测试。
- [x] Task 4：详情面板
  - Acceptance：截图所列主要信息、图表和估算说明可见，缺失数据不崩溃。
  - Verify：模型/视图测试与运行截图。
  - Files：Dashboard view、StatusBar controller、测试。
- [x] Task 5：集成与发布验证
  - Acceptance：格式、测试、自检、Release、签名、单实例和菜单点击全部通过。
  - Verify：项目命令与运行时检查。
  - Files：文档、开源记录、打包产物。

## 2026-08-11 — 订阅周期与图表交互

- [x] Task 6：订阅元数据 reader 与状态模型
  - Acceptance：合成 JWT 可解析本期开始、有效至和最后核验；缺失或损坏数据不泄露凭据。
  - Verify：JWT、日期、状态和安全单元测试。
  - Files：`CodexSubscriptionMetadata.swift`、对应测试。
- [x] Task 7：认证变化分类与账号副本同步
  - Acceptance：账号变化和同账号 token 轮换走不同刷新路径；切换离开前最新 live auth 原子回写受管目录。
  - Verify：Auth monitor、账号切换、权限和失败回滚测试。
  - Files：`CodexAuthMonitor.swift`、`CodexAccountManager.swift`、对应测试。
- [x] Task 8：订阅周期接入 Dashboard 与账号菜单
  - Acceptance：顶部显示完整周期和剩余天数；账号列表单行显示到期日；300pt 菜单不增宽且 Dashboard 不超过 450pt。
  - Verify：格式化测试、最长邮箱布局检查、安装后截图。
  - Files：`CodexDashboardStore.swift`、`CodexDashboardView.swift`、`StatusBarQuotaController.swift`。
- [x] Task 9：30 天柱状图交互
  - Acceptance：hover 展示详情，点击固定/取消，零值柱可命中，tooltip 不推动布局或关闭菜单。
  - Verify：选择状态测试和真实 NSMenu 鼠标交互验证。
  - Files：`CodexDashboardView.swift`、图表选择状态测试。
- [x] Task 10：完整回归与交付
  - Acceptance：多账号快速切换、同账号 token 轮换、离线失败保留、格式、测试、自检、打包、签名和单实例全部通过。
  - Verify：`tasks/subscription-chart-fix-spec.md` 中的完整命令和验收矩阵。
  - Files：测试、规划记录和构建产物。
