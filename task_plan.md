# Task Plan — 修复菜单栏点击

## Goal

让额度状态项保持现有两行外观，同时恢复原生菜单栏按钮的可点击区域和菜单弹出。

## Phases

- [complete] 1. 设计并实现原生按钮图像渲染，移除覆盖式自定义视图
- [complete] 2. 添加/更新渲染与状态项回归测试
- [complete] 3. 运行格式、测试、构建和打包
- [complete] 4. 启动新版并运行时验证按钮尺寸、菜单及单实例
- [complete] 5. 恢复菜单栏白色文字并重新验证打包
- [complete] 6. 修复受管 Codex 账号添加、验证与即时落库
- [complete] 7. 接入 CodexBar 本机 Token/费用 helper 与 Dashboard 数据层
- [complete] 8. 实现 CodexBar 风格详情面板并接入菜单
- [complete] 9. 完整测试、许可记录、Release 打包与真实运行验证

## Constraints

- 保留账号切换与额度读取逻辑。
- 不覆盖用户未关联的改动。
- 不增加第三方依赖；复用 AppKit 与现有 CodexBar 依赖。
- 费用/Token 无法可靠归属账号时必须标注为本机估算。

## Errors Encountered

| Error | Resolution |
|---|---|
| 旧实现运行时 `NSStatusBarButton` 为 `64×0` | 改为原生按钮图片承载显示内容 |
| Computer Use 无法读取无普通窗口的 accessory app 菜单状态 | 已用 LLDB 验证原生按钮为 `64×22`；菜单最终交互由用户单击确认 |
| 新增异步凭据等待首次编译触发 MainActor 隔离错误 | 将纯读取身份的静态方法标记为 `nonisolated` |
| Swift 6 拒绝把 MainActor 持有的 `FileManager` 发送给非隔离等待方法 | 保持等待状态机在 MainActor，身份解析本身仍为纯 `nonisolated` |
| 用户现有 CodexBar 配置属于旧 schema，helper 读取失败 | 为内嵌 helper 指定 QuotaFloat 自己的隔离配置路径，真实本机数据 smoke test 通过 |
| `swift format lint --strict Sources Tests` 缺少目录递归参数 | 改用 `swift format lint --recursive --strict Sources Tests` |
| 首次两次组合写入详细规格时包含空 hunk | 拆分为独立文件补丁后成功，不影响业务源码 |

## Next Plan — 账号稳定性与 CodexBar 风格界面

### Goal

让已保存账号切换和新增账号登录具备可重复、可诊断的状态转换；然后把详情菜单扩展为接近 CodexBar 截图的完整信息层级，同时保留当前菜单栏图标、额度数据来源和隐私边界。

### Phases

- [complete] 10. 修复登录进程封装：持续排空 stdout/stderr、增强 CLI 路径发现、超时清理完整进程组，并保留脱敏错误输出。
- [complete] 11. 修复账号切换事务：切换前取消旧账号额度/本机用量任务，原子替换后验证目标身份与指纹，再启动新账号刷新。
- [complete] 12. 做账号级状态隔离：额度缓存、面板状态和本机用量任务绑定账号身份，旧请求即使晚返回也不能污染新账号。
- [complete] 13. 复刻 CodexBar 风格面板：顶部服务切换、账号/套餐区、5 小时与周额度、Spark/额外额度、用量指标、图表和操作菜单。
- [complete] 14. 完成专项测试、运行时验收和 Release 打包。

## 2026-08-07 — Codex-only 面板对齐

- [complete] 15. 对照最新 CodexBar 菜单内容，收敛为只显示 Codex 的面板。
- [complete] 16. 重做 Codex 账号头部、每周/5 小时/Spark 额度、用量仪表盘、图表和额外额度布局。
- [complete] 17. 移除面板中的 Claude/Gemini 标签和旧平台清理入口，保留 Codex 账号管理与刷新操作。
- [complete] 18. 完成格式、测试、自检、arm64 打包、签名、安装和单实例启动验证。

## 2026-08-07 — Credits 语义修复

- [complete] 19. 核对 CodexBar Credits、Spark 窗口和重置额度的数据结构。
- [complete] 20. 开启真实 Codex Credits 返回，并把 numeric Credits 与重置额度次数分开建模。
- [complete] 21. 修正 Spark 5 小时/周窗口按名称和时长映射，避免数组顺序导致错栏。
- [complete] 22. 增加截图对应的数据组合测试，完成真实缓存、打包和安装运行验证。

## 2026-08-07 — 菜单紧凑度修复

- [complete] 23. 对照 CodexBar 的字体层级、区块留白、进度条和图表尺寸。
- [complete] 24. 将详情面板收敛到紧凑菜单卡密度，降低字号、内边距和固定承载高度。
- [complete] 25. 完成测试、打包、签名、安装和单实例启动验证。

## 2026-08-07 — 账号订阅日期

- [complete] 26. 核对 Codex OAuth、CLI RPC 和 CodexBar Web 数据模型是否包含购买/到期日期。
- [complete] 27. 确认当前 Codex 实际返回套餐、额度和 Credits，但不返回购买日期或合同到期日期。
- [complete] 28. 移除误导性的手工日期备注功能，仅保留真实订阅日期字段的自动接入能力。
- [complete] 29. 将菜单面板继续压缩，并完成自动字段映射、测试、打包和运行验证。

## 2026-08-11 — 订阅周期、账号同步与图表交互

- [complete] 30. 审阅当前认证、账号切换、缓存、菜单和 Chart 实现，确认现有并发隔离可复用。
- [complete] 31. 将详细规格、依赖顺序、风险、测试矩阵和成功标准写入 `tasks/subscription-chart-fix-spec.md`。
- [complete] 32. 实现订阅元数据 reader、账号级状态和同账号令牌轮换检测。
- [complete] 33. 实现实时凭据回写、刷新协调和账号切换专项回归。
- [complete] 34. 实现顶部周期行、账号菜单到期日和菜单自适应高度。
- [complete] 35. 实现柱状图 hover、点击固定、零值命中和 tooltip。
- [complete] 36. 完成格式、测试、自检、打包、签名、安装和真实交互验收。

### Next Acceptance Criteria

- 登录进程输出持续被读取；超时后不会遗留 `codex login` 子进程。
- 切换账号时，旧账号请求不能覆盖新账号；切换完成后邮箱、额度和菜单选中状态一致。
- 账号切换失败时，当前账号凭据和已保存账号列表保持不变。
- 面板缺失数据显示占位状态，费用明确标注为本机 Token 估算。
- `swift test`、严格格式检查、自检、Release 打包、签名和单实例运行验证全部通过。
