# 隐私与本地数据

Route Guard 的检查和事件记录在本机执行。应用没有自建数据接收服务器、账户系统或使用统计上报。

## 会读取什么

- Clash Verge / mihomo 的本地 Unix socket：版本、配置、策略组、规则和连接列表。
- 当前用户的 Clash Verge 配置文件中被选中节点的配置块，用于计算 SHA-256 指纹。
- Claude 进程信息、进程树和 socket，以及系统网卡、路由、代理与 PF 状态。
- 已安装的 Tailscale CLI 的状态，用于显示路由提示。

节点指纹只保存哈希；应用不把节点配置块、服务器密码或订阅写入事件记录。

## 会发起哪些网络请求

常规检查会对 `example.com` 发起 DNS 查询，以检查 fake-ip。用户启用可选出口探测后，应用通过 Clash 的混合端口请求 `static.cloudflareinsights.com/cdn-cgi/trace`，读取出口 IP 与国家信息。该选项默认关闭；请求由 Cloudflare 处理，Cloudflare 会看到所用代理的出口地址。

应用不把诊断日志上传到 GitHub。用户自行发布问题、截图或诊断文件时，应先检查并删除其中的私人信息。

## 数据存放位置

1.2.3 起项目更名为 Route Guard。为使升级继续读取原设置，系统服务标识、数据目录及日志路径保留旧版标识；这些内部兼容路径不作为产品名称。

| 内容 | 位置 |
| --- | --- |
| 系统服务设置、事件、审计记录和安装备份 | `/Library/Application Support/Claude Guard/` |
| 用户预览 / 测试模式数据 | `~/Library/Application Support/Claude Guard/`，或 `--config-dir` 指定目录 |
| 守护进程标准输出 | `/var/log/claude-guard.out.log` |
| 守护进程错误输出 | `/var/log/claude-guard.err.log` |
| 系统服务 IPC | `/var/run/com.local.claudeguard.sock` |

事件与连接审计可能包含节点名称、主机名、出口 IP、进程路径、PID 和路由检查结果。JSONL 文件达到约 10 MiB 时保留一份轮转文件。安装备份可能包含之前的设置与应用；它们不会自动上传。

## 源码与发行包清理

仓库排除本地备份、运行设置、环境变量文件、日志、构建缓存、机器交接记录和含真实连接信息的截图。发行包仅包含编译后的应用、通用安装资源和卸载脚本。构建会重映射源码路径并移除调试符号，打包后检查是否包含绝对用户目录和常见密钥格式。

默认卸载保留设置和安装备份。`sudo bash uninstall.sh --purge` 会删除应用支持目录及配置模板；系统输出日志仍留在 `/var/log/`，需要时可由管理员自行清理。
