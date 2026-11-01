# 架构

Route Guard 包含 SwiftUI / AppKit 菜单栏应用、root 守护进程、CLI，以及共享的 GuardKit。CProc 提供 libproc 桥接。Swift Package 不依赖外部包。

```text
GuardMenu / GuardCLI
        │ 本地 Unix socket，JSON 请求与响应
        ▼
GuardDaemon ── GuardKit
                 ├─ Clash API / 规则与节点解析
                 ├─ 系统代理 / TUN / 路由 / PF 状态
                 ├─ Claude 进程识别 / socket 连接审计
                 ├─ 设置与 JSONL 事件存储
                 └─ 风险确认与受管理进程关闭
```

## 服务与权限

LaunchDaemon 以 root 运行；IPC socket 限制为当前控制台用户可访问，并检查客户端身份。菜单栏应用与 CLI 通过它取得缓存快照和发送命令。未连接守护进程时，界面使用只读服务。`GuardDaemon --test` 强制禁用执行保护，不安装 PF。

`GuardSettings` 按字段容错解码，旧设置缺少新字段时保留节点批准与已有选项。初始设置只观察，默认管理 Desktop，CLI 管理默认关闭。

## 检查与故障处理

配置、策略组、规则、路由与 PF 各自异步采样，检查循环不等待单个缓慢请求。读取错误与已确认的错误状态分开处理；读取失败始终为黄色未确认状态，记录持续时间与重试次数、保留最近有效读数并继续重试，不因超过固定时限而升级为关闭条件。缓存的异常状态在其来源读取失败或过期后不能作为新的自动关闭依据。本地故障通过不同观测的二次确认去抖，未知观测会中断确认。

明确的 TUN 关闭、非 rule 模式、规则最终直连等关键风险优先显示红色。保护开关关闭时仍显示风险；只有 root 服务与保护开关同时启用，才自动关闭受管理进程。

关键采样队列与检查定时器使用 `userInitiated` QoS，LaunchDaemon 声明为 `Standard`，避免以 `Background` 运行。QoS 是调度意图，具体核心仍由 macOS 决定。菜单栏活动使用 `userInitiatedAllowingIdleSystemSleep`，退出时释放 token；保持监控活动不会主动禁止系统空闲睡眠。

## 规则与节点

`RuleAuditor` 检查 Claude 与常见遥测域名的首匹配规则，并递归解析策略组的实际叶子节点。不可静态展开的规则显示提示；最终直连属于关键风险。检查目标来自 `GuardSettings.proxyGroup`，默认 `🤖 AI`；所选组必须为 Selector，使用具体节点，不允许 dialer-proxy。快照提供可信的 Selector 列表供界面选择；切换时与检查轮次共用锁，暂停保护、清除旧批准并使旧出口探测缓存失效。规则、连接审计和可选出口探测均使用所选组名。

`ProfileFingerprint` 从当前用户的 Clash Verge YAML 提取对应节点块并计算 SHA-256。只持久化哈希，不写出 server/password 等配置字段。

## 运行时连接审计

`ClaudeLocator` 识别 Desktop、CLI 和相关子进程；`ProcScanner` 读取 socket，按源端口匹配 mihomo `/connections`。进程关闭前核对进程启动时间，避免 PID 复用导致误杀。

| 目标 | 判定 |
| --- | --- |
| Claude / 遥测经 AI | 正常 |
| Claude / 遥测经其他出口 | 异常提示 |
| 国内、私网和本机服务 | 放行 |
| GitHub API、仓库和资源域名 | 普通常规服务，遵循 Clash 分流 |
| 未知外部域名经其他代理 | 标准模式提示，严格模式标记异常 |
| 未知外部域名直连或持续未匹配到 Clash | 异常提示 |

连接审计只影响黄色提示，不单独触发进程关闭。

## 网络与 PF

TUN 设备、地址和代理端口来自 mihomo 实际配置，不要求固定网卡编号。公网探测地址的路由应指向当前 TUN。Tailscale 仅显示运行、exit node 和 MagicDNS 路由提示；源码不包含个人内网断言。

安装器将 `com.local.claudeguard` anchor 接入 `/etc/pf.conf`，放行 IPv6 loopback / link-local / multicast，其余 IPv6 出站丢弃。**该规则作用于系统全局，与进程保护开关独立。** 已安装 LaunchDaemon 使用 `--preserve-network`，避免常规服务重启重复初始化网络。

## 边界

应用不接管 Claude 启动，不承诺首包防泄漏。规则目录无法覆盖全部未知服务，API 读数和 socket 观测存在时间差。Intel、其他 Clash 客户端或自定义 mihomo 控制端点尚未完成兼容验证。可用 `CLAUDE_GUARD_CLASH_SOCKET` 指定本地 Unix socket；节点指纹仍依赖 Clash Verge 的标准配置位置。
