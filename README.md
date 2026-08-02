# codex额度显示器

<img src="Resources/AppIcon.png" alt="codex额度显示器 App Icon" width="128">

codex额度显示器 是一款原生 macOS 菜单栏额度工具，用于显示 Codex 的 5 小时额度、周额度和重置详情。

## 当前支持

- macOS 14 或更高版本
- **仅支持 Apple Silicon（M1、M2、M3、M4 等 arm64 Mac）**
- Codex

当前公开构建不支持 Intel Mac。

## 功能

- `CodexBarCore` 直接编译进应用，无需另外安装 CodexBar。
- 菜单栏直接显示 Codex 的 5 小时额度与周额度剩余百分比。
- 可添加多个 Codex ChatGPT 账号，并把额度显示与系统 Codex Desktop/CLI 登录一起切换。
- 打包应用显示独立 App 图标，便于在 Finder、启动台和“应用程序”中识别。
- 每 2 分钟刷新 Codex，也可以从菜单中手动立即刷新。
- 可在菜单中勾选“开机自启动”。
- 网络失败时保留最后一次成功数据，并标记缓存或过期状态。
- 无 Dock 运行图标，只在 macOS 顶部菜单栏显示。

## 安装

1. 从 GitHub Releases 下载 `CodexQuotaBar-版本号-macOS-arm64.zip`。
2. 解压 ZIP。
3. 将 `codex额度显示器.app` 拖入 macOS 的“应用程序”文件夹。
4. 打开后可在菜单中勾选“开机自启动”。

不要长期直接运行“下载”目录或项目 `dist` 目录中的应用，否则移动或更新文件后程序坞入口可能失效。

## 首次打开

当前公开构建使用 ad-hoc 签名，尚未经过 Apple Developer 公证。首次打开时 macOS 可能提示无法
验证开发者。

推荐操作：

1. 在 Finder 的“应用程序”中找到 codex额度显示器。
2. 按住 Control 点击应用，选择“打开”。
3. 在确认窗口中再次点击“打开”。

如果仍被阻止，请进入“系统设置 → 隐私与安全性”，在安全提示旁点击“仍要打开”。只应从本项目
官方 GitHub Releases 下载应用。

## 使用前准备

### Codex

登录 Codex Desktop、Codex CLI 或 Codex IDE 扩展均可，不要求必须单独登录 CLI。

codex额度显示器 当前读取 `CODEX_HOME/auth.json` 中的登录缓存；未设置 `CODEX_HOME` 时默认读取
`~/.codex/auth.json`。只要 Codex Desktop 的登录信息保存在这个位置，codex额度显示器 就能直接获取
官方额度。

如果用户将 Codex 凭证配置为只保存在 macOS 钥匙串，而本机没有 `auth.json`，当前版本暂时无法
读取，需要将 Codex 凭证存储方式设置为 `file`，或通过 Codex CLI 重新生成这份登录缓存。

## 多账号切换

1. 打开菜单栏图标，选择“添加 Codex 账号…”。应用会为该账号建立独立的 `CODEX_HOME`，并调用
   官方 `codex login` 浏览器登录流程。
2. 在“Codex 账号”列表点击一个账号。应用先保存当前系统账号，再用 `0600` 权限原子替换系统
   `auth.json`，随后刷新该账号额度。
3. 如果 Codex Desktop 正在运行，应用会询问是否重新打开。新启动的 CLI 直接使用新账号；正在运行
   的 Desktop 可能缓存旧登录，因此建议在没有执行中任务时重新打开。

多账号同步切换要求 Codex 使用文件凭据：

```toml
cli_auth_credentials_store = "file"
```

如果配置为 `keyring`，应用会在改动前拒绝切换并显示引导。

旧版本的 Claude/Kimi 聚合功能已经移除。若检测到旧版本保存的 Kimi 凭据，菜单会提供经过确认的
“清理旧版本凭据…”操作；应用不会静默删除用户密钥。

## 隐私

codex额度显示器 不包含遥测、广告或用户行为统计，也不会把凭证和额度数据上传给作者。
应用只连接 Codex/OpenAI 对应的官方接口。

详细说明参见 [PRIVACY.md](PRIVACY.md)。

## 从源码运行

要求：

- macOS 14+
- Apple Silicon Mac
- Swift 6.2+

```bash
git clone https://github.com/phlyals/CodexQuotaBar.git
cd CodexQuotaBar
swift run QuotaFloat
```

## 构建应用

```bash
./Scripts/package_app.sh
open dist/codex额度显示器.app
```

生成的是本机 ad-hoc 签名应用。正式公开发布若希望消除首次打开警告，需要 Apple Developer
Developer ID 签名与 Apple Notarization。

## 自检

```bash
swift run QuotaFloat --self-test
```

自检不会请求 Codex，也不会读取或切换真实账号凭据。

也可以运行单元测试：

```bash
swift test
```

## 开源许可

codex额度显示器 使用 [MIT License](LICENSE)。

项目依赖 `CodexBarCore`，`Package.swift` 将 CodexBar 固定到提交：

`3f3e2f4a112aa504c493ad5636c94e45df85fd03`

CodexBar 同样使用 MIT License，其原始许可文件保存在
`ThirdPartyLicenses/CodexBar-LICENSE.txt`，并会被复制进应用包。
