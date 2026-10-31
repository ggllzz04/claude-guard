import Foundation

public final class GuardService {
    public let mode: DaemonMode
    public let configDir: String

    private let settingsURL: String
    private let eventStore: JSONLStore<GuardEvent>
    private let findingStore: JSONLStore<TrafficFinding>

    private let workLock = NSLock()
    private let stateLock = NSLock()

    private var settings: GuardSettings
    private var lastSnapshot: Snapshot?
    private var lastState: GuardState = .unknown
    private var lastCheckSeverities: [String: Severity] = [:]
    private var protectedSince: Date?
    private var lastFindingKeys = Set<String>()
    private var findingFirstSeen: [String: Date] = [:]
    private let unmatchedSockets = UnmatchedSocketTracker()
    private var localRisks = RiskDebouncer()
    private var portReadFailures = ReadFailureTracker()
    private var interfaceReadFailures = ReadFailureTracker()
    private var fingerprintCache: (leaf: String, modified: Date, size: UInt64, value: String?)?
    private let configProbe = PollingProbe("configs", interval: 0.5) {
        try ClashClient(socketPath: GuardPaths.clashSocket(), timeout: 2).configs()
    }
    private let proxiesProbe = PollingProbe("proxies", interval: 1) {
        try ClashClient(socketPath: GuardPaths.clashSocket(), timeout: 3).proxies()
    }
    private let rulesProbe = PollingProbe("rules", interval: 3) {
        try ClashClient(socketPath: GuardPaths.clashSocket(), timeout: 3).rules()
    }
    private let routeProbe = PollingProbe("route", interval: 0.5) {
        try SystemProbe.checkedRouteInterface("1.1.1.1")
    }
    private let pfProbe = PollingProbe("pf", interval: 2) {
        let result = SystemProbe.pfAnchor("com.local.claudeguard")
        guard result.readable else { throw ClashError.socket("PF 状态读取失败或超时") }
        return result
    }

    // 出口探测会产生真实网络请求，放到后台每 5 分钟一次，不阻塞 0.5 秒一轮的检查。
    private let auxiliaryQueue = DispatchQueue(label: "com.local.claudeguard.auxiliary")
    private var cachedVersion: String?
    private var auxiliaryRunning = false
    private var auxiliaryTime: TimeInterval = 0
    private var auxiliaryResults: [GuardCheck] = []
    private var connectionResults: [ConnectionInfo] = []
    private var connectionsRunning = false
    private let connectionQueue = DispatchQueue(label: "com.local.claudeguard.connections")
    private let egressQueue = DispatchQueue(label: "com.local.claudeguard.egress")
    private var egressResult: EgressResult?
    private var egressRunning = false
    private var egressForce = false
    private var egressGeneration = 0
    private let egressInterval: TimeInterval = 300

    private struct EgressResult {
        var time: Date
        var ip: String?
        var country: String?
        var leaf: String
        var group: String
        var error: String?
    }

    public init(mode: DaemonMode, configDir: String = GuardPaths.configDir) {
        self.mode = mode
        self.configDir = configDir
        self.settingsURL = configDir + "/settings.json"
        self.eventStore = JSONLStore<GuardEvent>(path: configDir + "/events.jsonl")
        self.findingStore = JSONLStore<TrafficFinding>(path: configDir + "/findings.jsonl")
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        self.settings = GuardService.loadSettings(path: settingsURL, mode: mode)
    }

    // MARK: - Public

    public func currentSnapshot() -> Snapshot {
        stateLock.lock()
        let snapshot = lastSnapshot
        stateLock.unlock()
        if let snapshot { return snapshot }
        return refresh()
    }

    public func refresh() -> Snapshot {
        workLock.lock()
        defer { workLock.unlock() }

        // IPC 线程可能同时在改设置；本轮只用开始时的副本。
        let settings = currentSettings
        var checks: [GuardCheck] = []
        var node: NodeInfo?
        var clashVersion: String?
        var processes: [ClaudeProcessInfo] = []
        var findings: [TrafficFinding] = []
        var lastError: String?
        var config: ClashConfig?
        var proxies: [String: ProxyInfo] = [:]
        var rules: [RuleInfo] = []
        var connections: [ConnectionInfo] = []
        var clashOK = false
        var clashClient: ClashClient?

        var closedThisRound = false
        var enforcedThisRound = false
        // Close immediately after each safety stage; informational probes never delay enforcement.
        func enforceRisk() {
            guard !enforcedThisRound, mode == .root, settings.enforce,
                  checks.contains(where: { $0.severity == .critical }) else { return }
            enforcedThisRound = true
            let targets = ClaudeLocator.find().filter { settings.manages($0.app) }
            guard !targets.isEmpty else { return }
            let killed = ClaudeKiller.terminate(targets)
            if !killed.isEmpty {
                closedThisRound = true
                let reasons = checks.filter { $0.severity == .critical }.map(\.title).joined(separator: "、")
                let apps = Set(targets.filter { killed.contains($0.pid) }.map(\.app.title)).sorted().joined(separator: "、")
                let details = checks.filter { $0.severity == .critical }
                    .map { "\($0.title)：\($0.detail)" }.joined(separator: "；")
                record(.critical, "\(reasons)不满足要求，关闭了 \(apps) 进程",
                       "\(details)；PID \(killed.map(String.init).joined(separator: ", "))")
            }
        }

        // 控制接口是监测通道，不等同于代理本身。各项独立后台读取，任何一项忙碌都不阻塞本地保护。
        let configRead = configProbe.read()
        let proxiesRead = proxiesProbe.read()
        let rulesRead = rulesProbe.read()
        let routeRead = routeProbe.read()
        let pfRead = pfProbe.read()
        config = configRead.value
        proxies = proxiesRead.value ?? [:]
        rules = rulesRead.value ?? []
        clashVersion = currentVersion()
        clashOK = configRead.severity == .ok
        clashClient = try? ClashClient(socketPath: GuardPaths.clashSocket(), timeout: 2)
        lastError = [("/configs", configRead.severity, configRead.detail),
                     ("/proxies", proxiesRead.severity, proxiesRead.detail),
                     ("/rules", rulesRead.severity, rulesRead.detail)]
            .filter { $0.1 != .ok }.map { "\($0.0)：\($0.2)" }.first
        checks.append(check("clash", "Clash 状态",
                            configRead.severity == .ok ? "已连接 · mihomo \(clashVersion ?? "")" : "/configs：\(configRead.detail)",
                            configRead.severity, "bolt.fill"))
        for (id, title, path, severity, detail) in [
            ("proxyRead", "节点状态读取", "/proxies", proxiesRead.severity, proxiesRead.detail),
            ("rulesRead", "规则状态读取", "/rules", rulesRead.severity, rulesRead.detail)
        ] where severity != .ok {
            checks.append(check(id, title, "\(path)：\(detail)", severity, "arrow.clockwise"))
        }

        // 与最初脚本一样直接看本机入口；超时是未知，只有明确拒绝连接才计入故障确认。
        if let config, let port = [config.mixedPort, config.httpPort, config.socksPort].first(where: { $0 > 0 }) {
            do {
                let listening = try SystemProbe.proxyPortListening(port)
                portReadFailures.succeeded()
                checks.append(check("proxyPort", "代理入口", "127.0.0.1:\(port) · \(listening ? "监听中" : "拒绝连接，复核中")",
                                    localRisks.severity("proxyPort", failed: !listening), "network"))
            } catch {
                let now = ProcessInfo.processInfo.systemUptime
                portReadFailures.failed(at: now)
                checks.append(check("proxyPort", "代理入口", "读取失败：\(error.localizedDescription)，正在重试",
                                    portReadFailures.severity(at: now), "network"))
            }
        }

        enforceRisk()

        // 红色 = 流量可能不经 Clash 直接出去（会关闭被管理的 Claude）；其余只提示。
        if let config {
            let ruleMode = config.mode.lowercased() == "rule"
            checks.append(check("mode", "规则模式", ruleMode ? "rule" : "\(config.mode)（不是 rule）",
                                ruleMode ? .ok : .critical, "slider.horizontal.3"))

            let device = config.tunDevice
            var tunAddress: String?
            var interfaceError: String?
            do {
                tunAddress = try SystemProbe.checkedInterfaceIPv4(name: device)
                interfaceReadFailures.succeeded()
            } catch {
                interfaceError = error.localizedDescription
                interfaceReadFailures.failed(at: ProcessInfo.processInfo.systemUptime)
            }
            let expectedAddress = config.tunInet4.first.map { String($0.split(separator: "/").first ?? "") }
            let addressOK = tunAddress != nil && (expectedAddress == nil || expectedAddress == tunAddress)
            let tunSeverity: Severity
            if !config.tunEnabled || !config.autoRoute { tunSeverity = .critical }
            else if interfaceError != nil { tunSeverity = interfaceReadFailures.severity(at: ProcessInfo.processInfo.systemUptime) }
            else { tunSeverity = localRisks.severity("tun", failed: !addressOK) }
            let tunDetail: String
            if !config.tunEnabled {
                tunDetail = "未启用"
            } else if !config.autoRoute {
                tunDetail = "\(device) · 未开启自动路由"
            } else {
                tunDetail = interfaceError ?? "\(device) · \(tunAddress ?? "网卡未就绪，复核中")"
            }
            checks.append(check("tun", "TUN", tunDetail, tunSeverity, "network"))

            if let route = routeRead.value, let observedAt = routeRead.observedAt {
                let severity = localRisks.severity("routes", failed: device.isEmpty || route != device,
                                                   observedAt: observedAt)
                checks.append(check("routes", "网络路由", "1.1.1.1 → \(route)",
                                    max(severity, routeRead.severity), "arrow.triangle.branch"))
            } else {
                checks.append(check("routes", "网络路由", routeRead.detail, routeRead.severity, "arrow.triangle.branch"))
            }
            if routeRead.severity != .ok, routeRead.value != nil {
                checks.append(check("routeRead", "路由状态读取", routeRead.detail, routeRead.severity, "arrow.clockwise"))
            }

            checks.append(check("allowLan", "局域网",
                                config.allowLan ? "局域网可访问代理" : "已关闭",
                                config.allowLan ? .warning : .ok, "wifi.router"))

            checks.append(check("sniffer", "SNI",
                                config.snifferEnabled ? "已开启" : "建议开启 SNI 嗅探",
                                config.snifferEnabled ? .ok : .warning, "eye"))
        } else {
            checks.append(check("tun", "TUN", "等待读取配置，尚未确认关闭", .warning, "network"))
        }

        enforceRisk()

        if proxiesRead.value != nil {
            let groupIcon = "point.3.connected.trianglepath.dotted"
            let resolution = RuleAuditor.resolveNode(proxies: proxies, group: settings.proxyGroup)
            let leafInfo = proxies[resolution.leafName]
            // 红：AI 分组不存在，或者最终落到直连 / 拒绝。分组类型、嵌套、指纹这些都只提示。
            if proxies[settings.proxyGroup] == nil {
                checks.append(check("aiGroup", "AI 分组", "找不到 \(settings.proxyGroup)", .critical, groupIcon))
            } else if leafInfo?.isDirectLike == true {
                checks.append(check("aiGroup", "AI 分组", "最终落到直连：\(resolution.chain.joined(separator: " → "))", .critical, groupIcon))
            } else if leafInfo?.isReject == true {
                checks.append(check("aiGroup", "AI 分组", "最终落到拒绝：\(resolution.chain.joined(separator: " → "))", .critical, groupIcon))
            } else {
                let group = proxies[settings.proxyGroup]!
                checks.append(check("aiGroup", "AI 分组", "\(group.type) · \(group.now ?? "未选择")",
                                    group.type == "Selector" ? .ok : .warning, groupIcon))
            }

            let fingerprint = resolution.leafName.isEmpty ? nil : currentFingerprint(resolution.leafName)
            let approved = !settings.approvedNodeName.isEmpty &&
                settings.approvedNodeName == resolution.leafName &&
                settings.approvedFingerprint != nil &&
                settings.approvedFingerprint == fingerprint
            node = NodeInfo(
                group: settings.proxyGroup,
                name: resolution.leafName,
                type: resolution.leafType,
                delay: resolution.delay,
                isLeaf: resolution.isLeaf,
                chain: resolution.chain,
                fingerprint: fingerprint,
                approved: approved,
                dialerProxy: resolution.dialerProxy
            )

            if let error = resolution.error {
                checks.append(check("node", "AI 节点", error, .warning, "server.rack"))
            } else if !resolution.isLeaf {
                checks.append(check("node", "AI 节点", "当前选中的是分组：\(resolution.chain.joined(separator: " → "))", .warning, "server.rack"))
            } else if let dialer = resolution.dialerProxy, !dialer.isEmpty {
                checks.append(check("node", "AI 节点", "存在间接链路：\(dialer)", .warning, "server.rack"))
            } else if settings.approvedNodeName.isEmpty {
                checks.append(check("node", "AI 节点", "\(resolution.leafName) · 待确认", .warning, "server.rack"))
            } else if settings.approvedNodeName != resolution.leafName {
                checks.append(check("node", "AI 节点", "已换成 \(resolution.leafName)，批准的是 \(settings.approvedNodeName)", .warning, "server.rack"))
            } else if !approved {
                checks.append(check("node", "AI 节点", "\(resolution.leafName) · 节点配置有变化，请重新确认", .warning, "server.rack"))
            } else {
                // 延迟只是 Clash 最近一次测速的记录（Selector 分组不会自动测速，可能长期停在 0），不作为告警条件。
                let delay = resolution.delay > 0 ? "\(resolution.delay)ms" : "最近一次测速超时"
                checks.append(check("node", "AI 节点", "\(resolution.leafName) · \(delay)", .ok, "server.rack"))
            }

            if rulesRead.value != nil {
                let audit = RuleAuditor.audit(rules: rules, proxies: proxies, group: settings.proxyGroup, approvedLeaf: node?.name)
                let directRules = audit.filter { $0.status == .critical }
                let softRules = audit.filter { $0.status == .warning }
                if !directRules.isEmpty {
                    let examples = directRules.prefix(2).map(\.domain).joined(separator: "、")
                    checks.append(check("rules", "分流规则",
                                        "\(directRules.count) 个 Claude 域名会直连：\(examples)",
                                        .critical, "list.bullet.rectangle"))
                } else if !softRules.isEmpty {
                    let examples = softRules.prefix(2)
                        .map { "\($0.domain) → \($0.resolvedLeaf ?? $0.proxy)" }
                        .joined(separator: "；")
                    checks.append(check("rules", "分流规则",
                                        "\(softRules.count) 个域名没有显式走 AI：\(examples)",
                                        .warning, "list.bullet.rectangle"))
                } else {
                    checks.append(check("rules", "分流规则",
                                        "\(audit.count) 个域名显式走 AI",
                                        .ok, "list.bullet.rectangle"))
                }
            }
        } else {
            checks.append(check("node", "AI 节点", "等待读取节点，尚未确认异常", .warning, "server.rack"))
        }

        enforceRisk()

        var egressIP: String?
        if settings.canaryEnabled {
            let probeRule = RuleAuditor.firstMatch(domain: SystemProbe.egressProbeHost, rules: rules)?.0
            let probeViaAI = clashOK && rulesRead.severity == .ok && proxiesRead.severity == .ok && probeRule?.proxy == settings.proxyGroup
            let port = config?.mixedPort ?? 0
            if !clashOK {
                checks.append(check("egress", "出口", "连不上 Clash，暂停探测", .warning, "location.fill"))
            } else if !probeViaAI {
                // 探测流量只能走用户选定的策略组；没有对应规则时不发请求，免得探测本身走了别的出口。
                checks.append(check("egress", "出口",
                                    "\(SystemProbe.egressProbeHost) 没有显式走 AI，已跳过探测",
                                    .warning, "location.fill"))
            } else {
                scheduleEgressProbe(port: port, leaf: node?.name ?? "", group: settings.proxyGroup)
                egressIP = egressCheck(leaf: node?.name ?? "", group: settings.proxyGroup, into: &checks)
            }
        }

        // 系统代理开着却不指向 Clash，App 的流量会去别的代理或直接出去。
        let proxyIcon = "network.badge.shield.half.filled"
        let proxy = SystemProbe.systemProxy()
        if !proxy.readable {
            checks.append(check("systemProxy", "系统代理", "无法读取", .warning, proxyIcon))
        } else if !proxy.enabled {
            checks.append(check("systemProxy", "系统代理",
                                proxy.pacEnabled ? "仅 PAC，由 TUN 接管" : "未启用，由 TUN 接管",
                                proxy.pacEnabled ? .warning : .ok, proxyIcon))
        } else {
            let clashPorts = Set([config?.mixedPort, config?.httpPort, config?.socksPort]
                .compactMap { $0 }.filter { $0 > 0 })
            let local: Set<String> = ["127.0.0.1", "localhost", "::1"]
            let wrong = proxy.entries.filter { entry in
                !local.contains(entry.host.lowercased()) || (!clashPorts.isEmpty && !clashPorts.contains(entry.port))
            }
            let shown = Set(proxy.entries.map { "\($0.host):\($0.port)" }).sorted().joined(separator: "、")
            if let bad = wrong.first {
                checks.append(check("systemProxy", "系统代理", "\(bad.kind) 指向 \(bad.host):\(bad.port)，不是 Clash",
                                    .critical, proxyIcon))
            } else {
                checks.append(check("systemProxy", "系统代理", shown, .ok, proxyIcon))
            }
        }

        enforceRisk()

        // TUN 只接管 IPv4。本机有全局 IPv6 而 PF 封锁没生效时，IPv6 流量会绕过 Clash 直接出去，所以是红色。
        // 没有全局 IPv6 时就不存在这条路，PF 状态只作提示。
        let globalIPv6 = SystemProbe.globalIPv6Addresses()
        let hasIPv6 = !globalIPv6.isEmpty
        if pfRead.severity != .ok {
            checks.append(check("pfRead", "IPv6 防护状态读取", pfRead.detail,
                                hasIPv6 ? pfRead.severity : .warning, "arrow.clockwise"))
        }
        if let pf = pfRead.value {
            if pf.permissionDenied {
                checks.append(check("ipv6", "IPv6",
                                    hasIPv6 ? "有全局 IPv6，预览模式无法确认 PF 封锁" : "无全局 IPv6",
                                    hasIPv6 ? .warning : .ok, "globe"))
            } else if pf.effective {
                checks.append(check("ipv6", "IPv6", hasIPv6 ? "全局 IPv6 已封锁" : "无全局 IPv6 · 封锁已就绪", .ok, "globe"))
            } else {
                let reason = !pf.enabled ? "PF 已关闭" : (!pf.attached ? "封锁规则没有接入 PF" : "封锁规则没有加载")
                checks.append(check("ipv6", "IPv6",
                                    hasIPv6 ? "有全局 IPv6，\(reason)" : "无全局 IPv6 · \(reason)",
                                    hasIPv6 ? localRisks.severity("ipv6", failed: true,
                                                                  observedAt: pfRead.observedAt ?? 0) : .warning, "globe"))
            }
            if pf.effective || !hasIPv6 { _ = localRisks.severity("ipv6", failed: false) }
        } else {
            checks.append(check("ipv6", "IPv6", hasIPv6 ? "正在确认全局 IPv6 防护" : "无全局 IPv6", hasIPv6 ? .warning : .ok, "globe"))
        }

        enforceRisk()
        checks.append(contentsOf: informationalChecks())

        // 只审计、只关闭开关里管理的应用；没管理的照常运行，只在这里显示。
        let allClaude = ClaudeLocator.find()
        processes = allClaude.filter { settings.manages($0.app) }
        checks.append(check("claude", "Claude", claudeSummary(all: allClaude, settings: settings), .ok, "app.fill"))

        if clashOK && !processes.isEmpty {
            // 前面的检查要跑几十毫秒；紧挨着 socket 扫描重新取连接表，缩小两者的时间差。
            if let client = clashClient { connections = cachedConnections(client) }
            findings = ProcessAuditor.audit(
                processes: processes,
                connections: connections,
                group: settings.proxyGroup,
                approvedLeaf: node?.name,
                mode: settings.auditMode,
                unmatched: unmatchedSockets
            )
            // 同一条连接每轮都会重新生成 finding；保留首次发现时间，避免时间戳每轮都变。
            let now = Date()
            var firstSeen: [String: Date] = [:]
            for index in findings.indices {
                let id = findings[index].id
                let time = findingFirstSeen[id] ?? now
                firstSeen[id] = time
                findings[index].time = time
            }
            findingFirstSeen = firstSeen
        } else {
            findingFirstSeen = [:]
        }
        // 连接审计只提示，不关闭 Claude：代理本身正常时相信 Clash 的分流，
        // 真正会直连的情况已经由上面的 TUN / 路由 / 规则检查覆盖。
        let violations = findings.filter { $0.verdict == .violation }
        let auditWarnings = findings.filter { $0.verdict == .warning }
        if violations.isEmpty && auditWarnings.isEmpty {
            checks.append(check("audit", "连接审计",
                                processes.isEmpty ? "没有需要审计的 Claude" : "未发现异常连接",
                                .ok, "eye.fill"))
        } else if !violations.isEmpty {
            checks.append(check("audit", "连接审计",
                                "\(violations.count) 条异常，例如 \(violations[0].host) → \(violations[0].chain)",
                                .warning, "eye.fill"))
        } else {
            checks.append(check("audit", "连接审计",
                                "\(auditWarnings.count) 条提示，例如 \(auditWarnings[0].host) → \(auditWarnings[0].chain)",
                                .warning, "eye.fill"))
        }

        switch mode {
        case .root:
            checks.append(check("daemon", "守护", "root 守护进程", .ok, "shield.lefthalf.filled"))
        case .test:
            checks.append(check("daemon", "守护", "测试模式，不会影响 Claude", .warning, "shield.lefthalf.filled"))
        case .readOnly:
            checks.append(check("daemon", "守护", "预览模式，未安装守护进程", .warning, "shield.lefthalf.filled"))
        }

        let state = GuardState.evaluate(checks: checks, findings: findings, mode: mode, enforce: settings.enforce)

        if state == .protected {
            if protectedSince == nil { protectedSince = Date() }
        } else {
            protectedSince = nil
        }

        if mode == .root && settings.enforce && state == .blocked {
            enforceRisk()
            processes = ClaudeLocator.find().filter { settings.manages($0.app) }
            findings = []
        }

        // One risk event per transition, and one recovery event only after every critical check clears.
        let critical = checks.filter { $0.severity == .critical }
        let riskKey = critical.map { $0.id }.sorted().joined(separator: "|")
        let previousRisk = lastCheckSeverities.filter { $0.value == .critical }.map(\.key).sorted().joined(separator: "|")
        if !riskKey.isEmpty, riskKey != previousRisk {
            // A real close event above already includes the reason; avoid a second row for the same fault.
            if !closedThisRound {
                record(.critical, critical.map(\.title).joined(separator: "、") + "不满足要求",
                       "\(critical.map { "\($0.title)：\($0.detail)" }.joined(separator: "；"))；当前没有关闭进程")
            }
        } else if riskKey.isEmpty, !previousRisk.isEmpty {
            record(.ok, "代理已恢复", settings.enforce ? "关键保护条件已满足，继续保护" : "关键保护条件已满足")
        }
        let readIDs = ["clash", "proxyRead", "rulesRead", "routeRead", "pfRead"]
        for check in checks where readIDs.contains(check.id) && check.severity == .warning && lastCheckSeverities[check.id] != .warning {
            if check.detail.contains("失败") || check.detail.contains("超时") {
                record(.warning, "\(check.title)暂时无法读取", check.detail)
            }
        }
        for id in readIDs where lastCheckSeverities[id] == .warning || lastCheckSeverities[id] == .critical {
            if !checks.contains(where: { $0.id == id && $0.severity != .ok }) {
                record(.ok, "\(id == "clash" ? "Clash 状态" : id == "proxyRead" ? "节点状态" : id == "rulesRead" ? "规则状态" : id == "routeRead" ? "路由状态" : "IPv6 防护状态")读取已恢复", "已获得新的有效状态")
            }
        }
        lastCheckSeverities = Dictionary(checks.map { ($0.id, $0.severity) }, uniquingKeysWith: { a, _ in a })
        lastState = state

        var currentFindingKeys = Set<String>()
        for finding in findings where finding.verdict == .violation || finding.verdict == .warning {
            let key = "\(finding.id)-\(finding.verdict.rawValue)"
            currentFindingKeys.insert(key)
            if lastFindingKeys.insert(key).inserted {
                // 连接审计只提示，事件也用黄色；红色只留给会关闭 Claude 的条件。
                findingStore.append(finding)
            }
        }
        lastFindingKeys = currentFindingKeys

        let events = eventStore.recent(80)
        let snapshot = Snapshot(
            state: state,
            timestamp: Date(),
            checks: checks,
            node: node,
            egressIP: egressIP,
            processes: processes,
            findings: findings,
            events: events,
            settings: settings,
            selectorGroups: proxiesRead.severity == .ok ? Self.selectorGroups(in: proxies) : nil,
            clashVersion: clashVersion,
            daemonMode: mode,
            lastError: lastError,
            protectedSince: protectedSince
        )

        stateLock.lock()
        lastSnapshot = snapshot
        stateLock.unlock()
        return snapshot
    }

    public func blockClaude() -> Snapshot {
        if mode == .readOnly {
            var snapshot = currentSnapshot()
            snapshot.lastError = "只读模式无法杀进程"
            return snapshot
        }
        if mode == .test {
            record(.warning, "测试模式：未杀进程", "手动封锁请求被忽略")
            return refresh()
        }
        // 手动封锁和自动关闭一致：只关被管理的应用。
        let settings = currentSettings
        let targets = ClaudeLocator.find().filter { settings.manages($0.app) }
        guard !targets.isEmpty else { return refresh() }
        let killed = ClaudeKiller.terminate(targets)
        record(.critical, "手动封锁", "已关闭 \(killed.count) 个 Claude 进程")
        return refresh()
    }

    public func approveCurrentNode() -> Snapshot {
        _ = currentSnapshot()
        workLock.withLock {
            let snapshot = stateLock.withLock { lastSnapshot }
            guard let node = snapshot?.node, node.group == currentSettings.proxyGroup,
                  node.isLeaf, !node.name.isEmpty else {
                record(.warning, "无法批准节点", "当前没有可用的 AI 节点，请等待所选策略组状态刷新")
                return
            }
            guard let fingerprint = node.fingerprint, !fingerprint.isEmpty else {
                record(.warning, "无法批准节点", "无法读取节点配置指纹")
                return
            }
            let value = stateLock.withLock {
                settings.approvedNodeName = node.name
                settings.approvedNodeType = node.type
                settings.approvedFingerprint = fingerprint
                return settings
            }
            saveSettings(value)
            record(.ok, "已批准 AI 节点", "\(node.group) · \(node.name) · \(node.type)")
        }
        return refresh()
    }

    public func updateSettings(_ newSettings: GuardSettings) throws -> Snapshot {
        // 与检查和进程保护共用锁，切换组时不会再按旧组执行一轮保护。
        try workLock.withLock {
            let previous = currentSettings
            let reading = proxiesProbe.read()
            let groups = reading.severity == .ok ? reading.value.map(Self.selectorGroups(in:)) : nil
            let value = try newSettings.validatedUpdate(replacing: previous, selectorGroups: groups, mode: mode)
            guard value != previous else { return }
            stateLock.withLock {
                settings = value
                if value.proxyGroup != previous.proxyGroup {
                    egressGeneration += 1
                    egressResult = nil
                    egressForce = true
                }
            }
            if value.proxyGroup != previous.proxyGroup {
                findingFirstSeen = [:]
                lastFindingKeys = []
            }
            saveSettings(value)
            let changes = GuardService.describeChanges(from: previous, to: value)
            if !changes.isEmpty { record(.ok, "设置已更新", changes.joined(separator: "；")) }
        }
        return refresh()
    }

    static func selectorGroups(in proxies: [String: ProxyInfo]) -> [String] {
        proxies.filter { $0.value.type == "Selector" }.map(\.key).sorted()
    }

    static func describeChanges(from old: GuardSettings, to new: GuardSettings) -> [String] {
        func onOff(_ b: Bool) -> String { b ? "开" : "关" }
        var parts: [String] = []
        if old.proxyGroup != new.proxyGroup {
            parts.append("策略组 \(old.proxyGroup) → \(new.proxyGroup)；保护已暂停，请重新确认节点")
        }
        if old.enforce != new.enforce { parts.append("保护 \(onOff(new.enforce))") }
        if old.manageDesktop != new.manageDesktop { parts.append("管理 Claude Desktop \(onOff(new.manageDesktop))") }
        if old.manageCode != new.manageCode { parts.append("管理 Claude Code \(onOff(new.manageCode))") }
        if old.auditMode != new.auditMode { parts.append("审计模式 \(new.auditMode.title)") }
        if old.canaryEnabled != new.canaryEnabled { parts.append("出口探测 \(onOff(new.canaryEnabled))") }
        if old.notificationsEnabled != new.notificationsEnabled { parts.append("通知 \(onOff(new.notificationsEnabled))") }
        if old.webrtcStrict != new.webrtcStrict { parts.append("WebRTC 严格 \(onOff(new.webrtcStrict))") }
        if old.pollInterval != new.pollInterval { parts.append(String(format: "检查间隔 %.2f 秒", new.pollInterval)) }
        return parts
    }

    public func recentEvents(_ limit: Int = 80) -> [GuardEvent] {
        eventStore.recent(limit)
    }

    public func recentFindings(_ limit: Int = 100) -> [TrafficFinding] {
        findingStore.recent(limit)
    }

    public var currentSettings: GuardSettings {
        stateLock.lock()
        defer { stateLock.unlock() }
        return settings
    }

    /// 下一轮检查时重新探测出口（“重新检测”按钮用）。
    public func requestEgressProbe() {
        stateLock.lock()
        egressForce = true
        stateLock.unlock()
    }

    // MARK: - Private

    private func currentFingerprint(_ leaf: String) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: GuardPaths.profilePath),
              let modified = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? UInt64 else { return nil }
        if let cached = fingerprintCache, cached.leaf == leaf, cached.modified == modified, cached.size == size {
            return cached.value
        }
        let value = ProfileFingerprint.fingerprint(leafName: leaf)
        fingerprintCache = (leaf, modified, size, value)
        return value
    }

    private func currentVersion() -> String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return cachedVersion
    }

    private func cachedConnections(_ client: ClashClient) -> [ConnectionInfo] {
        stateLock.lock()
        let cached = connectionResults
        let schedule = !connectionsRunning
        if schedule { connectionsRunning = true }
        stateLock.unlock()
        if schedule {
            connectionQueue.async { [weak self] in
                let fresh = try? client.connections()
                guard let self else { return }
                self.stateLock.lock()
                // Drop stale connections on failure; they must never appear as a current audit result.
                self.connectionResults = fresh ?? []
                self.connectionsRunning = false
                self.stateLock.unlock()
            }
        }
        return cached
    }

    private func informationalChecks() -> [GuardCheck] {
        stateLock.lock()
        let cached = auxiliaryResults
        let due = !auxiliaryRunning && ProcessInfo.processInfo.systemUptime - auxiliaryTime >= 2
        if due { auxiliaryRunning = true }
        stateLock.unlock()
        if due {
            auxiliaryQueue.async { [weak self] in
                guard let self else { return }
                let result = self.probeInformationalChecks()
                let version = try? ClashClient(socketPath: GuardPaths.clashSocket(), timeout: 0.5).version()
                self.stateLock.lock()
                self.auxiliaryResults = result
                if let version { self.cachedVersion = version }
                self.auxiliaryTime = ProcessInfo.processInfo.systemUptime
                self.auxiliaryRunning = false
                self.stateLock.unlock()
            }
        }
        return cached
    }

    private func probeInformationalChecks() -> [GuardCheck] {
        var checks: [GuardCheck] = []
        // TUN 正常时 DNS 查询也会被它接管；没拿到 fake-ip 只算 DNS 泄漏风险，不是直连。
        let dns = SystemProbe.dnsCanaryFakeIP()
        if dns == true {
            checks.append(check("dns", "DNS", "example.com → 198.18.x.x", .ok, "network"))
        } else if dns == false {
            checks.append(check("dns", "DNS", "没有返回 fake-ip，DNS 可能没走 Clash", .warning, "network"))
        } else {
            checks.append(check("dns", "DNS", "无法判断", .warning, "network"))
        }

        let ts = SystemProbe.tailscale()
        if !ts.installed {
            checks.append(check("tailscale", "Tailscale", "未安装", .ok, "point.3.filled.connected.trianglepath.dotted"))
        } else if !ts.running {
            checks.append(check("tailscale", "Tailscale", "已停止", .ok, "point.3.filled.connected.trianglepath.dotted"))
        } else if ts.exitNode {
            checks.append(check("tailscale", "Tailscale", "exit node 已开启，可能影响公网路由", .warning, "point.3.filled.connected.trianglepath.dotted"))
        } else {
            let magic = SystemProbe.routeInterface("100.100.100.100")
            let tunDevice = try? ClashClient(socketPath: GuardPaths.clashSocket(), timeout: 0.5).configs().tunDevice
            if let magic, let tunDevice, !tunDevice.isEmpty, magic == tunDevice {
                checks.append(check("tailscale", "Tailscale", "MagicDNS 路由走 Clash，可能被劫持", .warning, "point.3.filled.connected.trianglepath.dotted"))
            } else {
                checks.append(check("tailscale", "Tailscale", "运行中 · MagicDNS 正常", .ok, "point.3.filled.connected.trianglepath.dotted"))
            }
        }

        return checks
    }

    private func scheduleEgressProbe(port: Int, leaf: String, group: String) {
        stateLock.lock()
        let last = egressResult
        let due = egressForce || last == nil || last!.leaf != leaf || last!.group != group ||
            Date().timeIntervalSince(last!.time) >= egressInterval
        guard due, !egressRunning else { stateLock.unlock(); return }
        egressRunning = true
        egressForce = false
        let generation = egressGeneration
        stateLock.unlock()

        egressQueue.async { [weak self] in
            let probe = SystemProbe.egressProbe(proxyPort: port)
            let result = EgressResult(time: Date(), ip: probe?.ip, country: probe?.country, leaf: leaf, group: group,
                                      error: probe == nil ? "探测失败" : nil)
            guard let self else { return }
            self.stateLock.lock()
            // 切换组前已在途的请求不能成为新组的探测结果（含 A → B → A）。
            if self.egressGeneration == generation { self.egressResult = result }
            self.egressRunning = false
            self.stateLock.unlock()
        }
    }

    /// 出口只作提示：IP 在中国、或探测失败都是黄色，不会关闭 Claude。
    private func egressCheck(leaf: String, group: String, into checks: inout [GuardCheck]) -> String? {
        stateLock.lock()
        let result = egressResult
        stateLock.unlock()
        guard let result, result.leaf == leaf, result.group == group else {
            checks.append(check("egress", "出口", "探测中…", .ok, "location.fill"))
            return nil
        }
        guard let ip = result.ip else {
            checks.append(check("egress", "出口", result.error ?? "探测失败", .warning, "location.fill"))
            return nil
        }
        let country = result.country ?? ""
        let domestic = country.uppercased() == "CN"
        checks.append(check("egress", "出口",
                            domestic ? "\(ip) · 出口在中国大陆" : "\(ip) · \(country)",
                            domestic ? .warning : .ok, "location.fill"))
        return ip
    }

    private func claudeSummary(all: [ClaudeProcessInfo], settings: GuardSettings) -> String {
        let parts = ClaudeApp.allCases.compactMap { app -> String? in
            let count = all.filter { $0.app == app }.count
            guard count > 0 else { return nil }
            return "\(app.title) \(count) 个\(settings.manages(app) ? "" : "（未管理）")"
        }
        return parts.isEmpty ? "未运行" : parts.joined(separator: " · ")
    }

    private func check(_ id: String, _ title: String, _ detail: String,
                       _ severity: Severity, _ icon: String) -> GuardCheck {
        GuardCheck(id: id, title: title, detail: detail, severity: severity, icon: icon)
    }

    private func record(_ severity: Severity, _ title: String, _ detail: String) {
        eventStore.append(GuardEvent(severity: severity, title: title, detail: detail))
    }

    private func saveSettings(_ settings: GuardSettings) {
        if let data = try? GuardJSON.encoder.encode(settings) {
            try? data.write(to: URL(fileURLWithPath: settingsURL), options: .atomic)
        }
    }

    private static func loadSettings(path: String, mode: DaemonMode) -> GuardSettings {
        var settings = GuardSettings.default
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let decoded = try? GuardJSON.decoder.decode(GuardSettings.self, from: data) {
            settings = decoded
        }
        if mode != .root { settings.enforce = false }
        return settings
    }
}
