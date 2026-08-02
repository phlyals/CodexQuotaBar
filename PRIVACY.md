# QuotaFloat 隐私说明

QuotaFloat 是本地运行的开源 macOS 工具，不包含账号系统、广告、遥测或用户行为统计。

## 凭证如何读取

- **Codex**：读取 `CODEX_HOME/auth.json` 中由 Codex Desktop、CLI 或 IDE 扩展共享的本机登录
  缓存；未设置 `CODEX_HOME` 时默认读取 `~/.codex/auth.json`。
- **Codex 多账号**：每个已添加账号保存在
  `~/Library/Application Support/QuotaFloat/CodexHomes/` 下的独立目录；账号索引保存在同级
  `managed-codex-accounts.json`。目录和凭据文件分别使用 `0700`、`0600` 权限。
- **系统账号切换**：只在用户点击账号时，先备份当前系统账号，再原子替换系统 Codex
  `auth.json`。应用不支持在 Keychain-only 模式下切换。

QuotaFloat 不会把 Codex 凭证写入项目目录，也不会在正常日志中输出凭证内容。

Claude 和 Kimi 聚合功能已移除。应用不会再读取它们的凭据。检测到旧版 QuotaFloat 保存的 Kimi
凭据时，仅显示手动清理入口；只有用户确认后才会删除旧钥匙串项目和旧密钥文件。

## 网络请求

额度刷新只会连接 Codex/OpenAI 对应的官方接口。QuotaFloat 不会把凭证、额度数据或使用信息上传给
QuotaFloat 作者、分析平台、广告服务或其他非必要第三方。

## 本地数据

最后一次成功获取的额度会缓存在：

`~/Library/Application Support/QuotaFloat/quota-cache.json`

缓存用于断网或接口失败时继续显示旧数据。用户可以退出 QuotaFloat 后自行删除该文件。

## 上游依赖

QuotaFloat 内置开源的 `CodexBarCore` 取数能力。上游许可证保存在
`ThirdPartyLicenses/CodexBar-LICENSE.txt`。
