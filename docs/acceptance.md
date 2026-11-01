# 验证清单

## 自动验证

```bash
bash scripts/test.sh
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
"$BIN/GuardBench" --self-test
python3 scripts/regression-polling.py
```

- Swift Testing：域名边界、首匹配规则、默认设置、自定义策略组与旧设置/快照兼容、告警优先级、持续读取失败不触发关闭、失效缓存不可执行保护和不同观测去抖。
- GuardBench 自检：进程范围、PID 身份校验、常规外部服务路由，以及仅对临时 mock 进程执行的保护行为。
- 隔离回归：自定义组切换、无效目标拒绝、暂停保护与批准清除、设置持久化，以及 HTTP 帧、慢读、超时、格式异常、恢复、长时间多端点不可读与过期风险缓存不关闭新进程、确认 TUN / 模式 / 规则故障和本地端口失败。

回归结果位于 `build/polling-regression.json`，包含本机观测数据，禁止直接上传。

## 发行包

- [ ] `bash scripts/package-release.sh` 成功；DMG 校验与代码签名验证通过。
- [ ] `SHA256SUMS.txt` 与本次 DMG、ZIP、卸载脚本相符。
- [ ] 解压 ZIP 并挂载 DMG，逐项检查安装资源、版本与架构。
- [ ] 暂存源码与解包产物通过 `scripts/check-privacy.py`，并另行运行密钥扫描工具。
- [ ] 公开仓库的可见性正确，Release 附件、说明与标签对应同一提交。

## 需要交互验证的系统操作

以下项目需要有意修改系统状态或控制真实 Claude，不属于自动发布脚本：

- [ ] 拖入 Applications、管理员初始化、Merge 手动启用和观察模式。
- [ ] 批准节点、保护范围、设置保存和升级保留设置。
- [ ] 菜单栏图标、窗口、通知、关闭窗口后持续运行与登录启动。
- [ ] 更新后只读检查电源断言，确认应用不再持有 `PreventUserIdleSystemSleep`；睡眠与唤醒交互仅在用户明确同意后验证。
- [ ] 在受控环境启用保护并注入故障，确认只关闭选定范围内的真实 Claude。
- [ ] 确认 PF 的全局 IPv6 影响符合预期，IPv4 与本地链路使用正常。
- [ ] 卸载后应用、服务与 PF anchor 移除；默认保留数据，`--purge` 清理应用支持目录。

请用虚构节点名与保留地址记录案例。需要提交日志时，先删除主机名、节点名、出口地址、用户路径和其他私人内容。
