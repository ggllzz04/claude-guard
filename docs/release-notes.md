**Route Guard 1.2.3**：统一项目、应用和发行包名称。

### 本版变化

- 项目和应用显示名统一为 **Route Guard**，仓库改为 `ggllzz04/route-guard`。
- README、窗口、菜单、通知及应用的版本信息使用新名称。
- 新安装包为 `Route-Guard-1.2.3-arm64.dmg` / `.zip`，Merge 模板改为 `RouteGuard.yaml`，CLI 为 `route-guardctl`。
- 保留旧版服务标识、数据目录及 CLI 兼容入口；升级继续使用已有设置、节点批准和保护开关。
- 安装器备份并迁移旧名称应用；新服务验证通过后再清理旧应用路径。进程识别和保护规则保持原有支持范围。

### 支持与安装

macOS 26+、Apple Silicon / arm64，需要 Clash Verge Rev / mihomo、TUN、rule 模式与 `🤖 AI` Selector。下载 DMG，将 Route Guard 拖到「应用程序」，打开并完成初始化。

新安装默认只观察；确认节点和检查结果后，再按需开启保护。已启用的旧版 Merge 可以继续使用；新安装请导入仓库中的 `config/RouteGuard.yaml`。

### 使用说明

- ad-hoc 签名，尚未进行 Developer ID 签名或 Apple 公证；首次启动请按 macOS「隐私与安全性」提示处理。
- 安装器加载的 PF 规则阻断系统全局 IPv6 出站（loopback、link-local、multicast 除外），与进程保护开关独立。
- 保护只覆盖运行期间的检查，无法保证首包防泄漏。连接审计问题只提示。
- 自动验证使用隔离 mock；发布流程不重装本机服务、不对真实客户端执行故障注入。

### 附件

- `Route-Guard-1.2.3-arm64.dmg`：推荐安装方式。
- `Route-Guard-1.2.3-arm64.zip`：同一应用的 ZIP 包。
- `uninstall.sh`：卸载脚本，支持 `--purge` 清除应用支持目录。
- `SHA256SUMS.txt`：附件的 SHA-256 校验清单。
