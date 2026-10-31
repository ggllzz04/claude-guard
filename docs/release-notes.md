Claude Guard 首个 GitHub Release，沿用本地开发版本号 **1.2.2**。

### 支持范围

- macOS 26 或更高。
- Apple Silicon / arm64；Intel 尚未验证。
- Clash Verge Rev / mihomo、TUN、rule 模式与 `🤖 AI` Selector。

### 本版内容

- Liquid Glass 菜单栏面板、root 守护进程与命令行工具。
- TUN、路由、系统代理、节点指纹、首匹配规则与连接审计。
- 默认观察模式，明确启用后才自动关闭受管理进程。
- 对短暂读取失败保留宽限期；确认关键风险时执行保护。
- 安装升级、PF IPv6 anchor、本地备份与卸载脚本。
- 清理个人网络绑定与私人配置，补齐测试、隐私说明和发布流程。

### 安装

下载 arm64 DMG，将应用拖入「应用程序」，打开并点击「初始化并安装」。在 Clash Verge 中启用通用 Merge 配置和 TUN，批准当前节点后再按需开启保护。升级保留已有设置和保护开关。

### 需要了解

- 使用 ad-hoc 签名，**未进行 Developer ID 签名或 Apple 公证**。按 macOS 的「隐私与安全性」提示处理首次启动。
- 安装器启用的 PF 规则阻断系统全局 IPv6 出站（loopback、link-local、multicast 除外），独立于进程保护开关。
- 本工具在运行期间检查，不能保证首包防泄漏。连接审计问题只提示。
- 自动验证使用隔离 mock；发布流程未对真实 Claude 执行故障注入，也未自动重装本机服务。

### 附件

- `Claude-Guard-1.2.2-arm64.dmg`：推荐安装方式。
- `Claude-Guard-1.2.2-arm64.zip`：同一应用的 ZIP 包。
- `uninstall.sh`：卸载；`sudo bash uninstall.sh --purge` 可同时清除应用支持目录。
- `SHA256SUMS.txt`：附件 SHA-256 校验清单。
