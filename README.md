<p align="center"><img src="docs/app-icon.png" width="112" alt="Route Guard 图标"></p>

# Route Guard

macOS 菜单栏应用，用于检查受管理的 AI 客户端是否通过 Clash Verge / mihomo 的指定策略组联网（默认 `🤖 AI`，可自定义），并在确认关键代理条件失效时关闭相关进程。当前支持固定的桌面客户端及其配套命令行工具，支持范围由内置识别规则确定。

**当前版本：1.2.4 · macOS 26+ · 发行包支持 Apple Silicon（arm64）。**

本项目为独立工具，与被检查服务及代理客户端的提供方没有隶属关系。源码与发行包公开可见，使用条款见 [LICENSE](LICENSE)。

## 功能

- 菜单栏状态、健康检查、规则检查、连接审计和本地事件记录。
- 读取 mihomo 实际配置、TUN 状态、系统路由与代理设置。
- 目标 Selector 可从已有策略组选择，也可手动输入名称后应用。
- 检查客户端服务与常见遥测域名的首条命中规则，以及所选节点的配置指纹。
- root 守护进程独立运行，菜单栏界面关闭后继续检查。
- 观察模式默认开启；用户主动启用保护后，才会自动关闭受管理的进程。
- PF anchor 阻断全局 IPv6 出站，保留 loopback、link-local 和 multicast。
- 提供命令行状态查询、安装升级、完整卸载和本地备份。

## 系统要求

| 项目 | 要求 |
| --- | --- |
| 系统 | macOS 26 或更高，界面使用 Liquid Glass |
| 当前安装包 | Apple Silicon / arm64；Intel 构建尚未验证 |
| 代理 | Clash Verge Rev / mihomo，开启 TUN、auto-route 和 rule 模式 |
| 策略组 | 任意名称的 Selector，选择具体代理节点；默认 `🤖 AI`，可在设置中更改 |
| 首次安装 | 管理员权限，用于安装本地守护进程和 PF 规则 |
| 源码构建 | Swift 6.2+ 与 macOS 26+ SDK（Xcode 或 Command Line Tools） |
| 打包及回归 | Python 3.10+，其余打包工具由 macOS 提供 |

## 下载与安装

1. 在本仓库的 [Releases](https://github.com/ggllzz04/route-guard/releases) 下载 `Route-Guard-1.2.4-arm64.dmg`。
2. 打开 DMG，将 **Route Guard.app** 拖到「应用程序」。
3. 打开应用，点击「初始化并安装」，在 macOS 授权窗口中输入管理员密码。
4. 在 Clash Verge 中启用 TUN，准备一个 Selector 并选择具体节点。导入并启用 [config/RouteGuard.yaml](config/RouteGuard.yaml) 作为 Merge 配置；若组名不是 `🤖 AI`，请先将模板内所有规则的目标组名改为实际名称。安装器只会在已有 profiles 目录中放置模板，**不会替你启用 Merge**，模板也不包含代理节点或订阅。
5. 在「设置 → 目标策略组」选择或输入同名 Selector，点击「应用策略组」。确认面板检查结果和当前节点，在应用中批准节点，最后按需开启保护。

安装默认保留观察模式；升级保留已有设置、节点批准和保护开关。**安装器会启用 PF IPv6 阻断，即使进程保护开关尚未开启，也会影响其他应用的全局 IPv6 出站。**

发行包使用 ad-hoc 签名，未使用 Developer ID 签名或 Apple 公证。若 Gatekeeper 阻止启动，确认下载来源后，按系统提示在「系统设置 → 隐私与安全性」中允许打开。签名检查和 SHA-256 校验不代表 Apple 公证。

下载同一 Release 的 `SHA256SUMS.txt`，在包含全部附件的目录中校验：

```bash
shasum -a 256 -c SHA256SUMS.txt
```

## 自定义策略组

在「设置 → 目标策略组」选择已有 Selector，或输入与 Clash 完全一致的名称，然后点击「应用策略组」。自动保存只用于其他选项，输入组名不会立即切换；不存在的名称、非 Selector 或暂时无法确认的列表会被拒绝。

切换组名后，Route Guard 会关闭自身的进程保护并清除旧节点确认。检查分流规则与新节点、重新确认后，再按需启用保护。同组修改其他选项、从旧版本升级时，已有节点确认继续保留。

此设置只改变检查目标。请自行确保 Merge 中的客户端和遥测规则指向同一组；使用模板时，将全部 `🤖 AI` 规则目标替换为实际名称。如果需要出口探测，还需为 `static.cloudflareinsights.com` 添加指向该组的显式规则（模板中提供了注释示例）。

## 保护行为

| 情况 | 行为 |
| --- | --- |
| 未安装守护进程 | 界面回退到只读检查 |
| 守护进程已安装、保护关闭 | 检查并显示风险，不自动关闭受管理客户端 |
| 保护开启、确认 TUN 关闭 / 非 rule 模式 / 规则最终直连等严重风险 | 关闭受管理的客户端进程 |
| API 短时读取失败 | 黄灯重试，保留最近有效读数 |
| API 至少连续失败 3 次且持续 15 秒 | 视为持续失去监测能力，保护开启时关闭受管理进程 |
| 节点变更、指纹变化、DNS、连接审计或出口探测问题 | 提示检查，不单独触发自动关闭 |

本地端口、网卡、路由和 PF 故障需要两次不同观测确认。明确读到 TUN 关闭、模式错误、规则直连等状态时，可直接判定严重风险。默认检查间隔为 0.5 秒，实际响应时间受系统调度和检查耗时影响。

默认管理 AI 桌面客户端及其内置编程工具；命令行编程工具默认不管理，可在「设置 → 保护范围」调整。GitHub 等常规外部服务遵循 Clash 自身分流；连接审计只提示。

**应用不接管客户端启动，也无法保证首个数据包绝不外泄。它提供运行中的检查和进程关闭，不是逐包防火墙或沙箱。**

## 从源码构建

```bash
git clone https://github.com/ggllzz04/route-guard.git
cd route-guard
bash scripts/build-app.sh
open "build/Route Guard.app"
```

未安装守护进程时，上面的应用以只读模式检查；已有守护进程时会连接现有服务。构建脚本不会安装服务，也不会修改 Clash、PF 或进程保护设置。

生成 DMG、ZIP、卸载脚本和 SHA-256 清单：

```bash
bash scripts/package-release.sh
# 输出：build/release/
```

版本由 `VERSION` 与 `BUILD_NUMBER` 统一管理。完整开发与发布步骤见 [CONTRIBUTING.md](CONTRIBUTING.md) 和 [docs/releasing.md](docs/releasing.md)。

## 命令行

初始化后 CLI 位于 `/usr/local/bin/route-guardctl`：

```bash
route-guardctl status
route-guardctl check --json
route-guardctl events --json
route-guardctl findings --json
route-guardctl approve  # 批准当前节点
route-guardctl block    # 立即关闭受管理进程
```

使用临时目录运行一次无强制动作的检查，结果可能包含本机信息，请仅保存在本地：

```bash
PREVIEW_DIR="$(mktemp -d)"
build/bin/GuardDaemon --test --once --config-dir "$PREVIEW_DIR"
```

## 卸载

从 Release 或 DMG 中取得 `uninstall.sh`：

```bash
sudo bash uninstall.sh
# 同时删除设置、日志数据和安装备份：
sudo bash uninstall.sh --purge
```

源码仓库内可使用 `sudo bash scripts/uninstall.sh`。卸载会移除应用、CLI、LaunchDaemon、LaunchAgent 及本项目的 PF anchor；默认保留本地设置和安装备份。系统输出日志不由卸载脚本清理，位置见隐私说明。

## 文档与项目结构

- [架构与检查边界](docs/architecture.md)
- [验证清单](docs/acceptance.md)
- [隐私与本地数据](PRIVACY.md)
- [安全问题报告](SECURITY.md)
- [更新记录](CHANGELOG.md)

```text
Sources/GuardKit/     规则、进程、代理、系统检查与 IPC
Sources/GuardDaemon/  root 守护进程
Sources/GuardMenu/    菜单栏应用
Sources/GuardCLI/     命令行工具
Sources/GuardMock/    隔离测试进程
Sources/GuardBench/   隔离回归测试宿主
Sources/CProc/        libproc C 桥接
Tests/GuardKitTests/  Swift Testing 测试
config/              无节点和订阅的配置模板
pf/                  IPv6 anchor
scripts/             构建、打包、验证和安装卸载
```
