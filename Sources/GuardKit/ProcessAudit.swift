import Foundation
import CProc

public struct ProcInfo: Identifiable, Equatable, Sendable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var ppid: Int32
    public var uid: uid_t
    public var gid: gid_t
    public var startTime: UInt64
    public var path: String
}

public struct SocketInfo: Identifiable, Equatable, Sendable {
    public var id: String { "\(pid)-\(localPort)-\(remotePort)-\(remoteAddr)" }
    public var pid: Int32
    public var family: Int32
    public var proto: Int32
    public var state: Int32
    public var localPort: UInt16
    public var remotePort: UInt16
    public var localAddr: String
    public var remoteAddr: String
}

public enum ProcScanner {
    public static func all() -> [ProcInfo] {
        var pointer: UnsafeMutablePointer<Int32>?
        var count: Int32 = 0
        guard guard_list_pids(&pointer, &count) == 0, let pids = pointer else { return [] }
        defer { guard_free(pids) }

        var result: [ProcInfo] = []
        result.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            let pid = pids[index]
            guard pid > 0 else { continue }
            var info = guard_proc_info()
            guard guard_get_proc_info(pid, &info) == 0 else { continue }
            let path = withUnsafePointer(to: &info.path) {
                $0.withMemoryRebound(to: CChar.self, capacity: 4096) { String(cString: $0) }
            }
            result.append(ProcInfo(pid: pid, ppid: info.ppid, uid: info.uid, gid: info.gid,
                                   startTime: info.start_usec, path: path))
        }
        return result
    }

    /// pid 当前对应进程的启动时间；进程不存在时返回 nil。
    public static func startTime(pid: Int32) -> UInt64? {
        var info = guard_proc_info()
        guard guard_get_proc_info(pid, &info) == 0 else { return nil }
        return info.start_usec
    }

    public static func argv(pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard guard_get_argv(pid, &buffer, buffer.count) == 0 else { return "" }
        return String(cString: buffer)
    }

    public static func sockets(pid: Int32) -> [SocketInfo] {
        var pointer: UnsafeMutablePointer<guard_socket_info>?
        var count: Int32 = 0
        guard guard_list_sockets(pid, &pointer, &count) == 0, let sockets = pointer else { return [] }
        defer { guard_free(sockets) }

        var result: [SocketInfo] = []
        for index in 0..<Int(count) {
            let socket = sockets[index]
            let local = withUnsafePointer(to: socket.local_addr) {
                $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) }
            }
            let remote = withUnsafePointer(to: socket.remote_addr) {
                $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) }
            }
            result.append(SocketInfo(
                pid: pid,
                family: socket.family,
                proto: socket.protocol,
                state: socket.state,
                localPort: socket.local_port,
                remotePort: socket.remote_port,
                localAddr: local,
                remoteAddr: remote
            ))
        }
        return result
    }
}

/// 只识别 Claude 本体：可执行文件位于 Claude 自己的安装位置（或 node 运行的是 claude-code 包）。
/// 旧版把 Claude 的所有子进程都算进来，Claude Code 跑的 npm / curl / 测试程序一旦走了别的节点，
/// 就会连带关闭整个 Claude Code。子进程不再审计；只有关闭 Claude 时才会连同子进程一起结束。
public enum ClaudeLocator {
    public static func classify(path: String, argv: () -> String) -> ClaudeApp? {
        // 独立测试宿主只识别指定 mock，绝不把真实 Claude 纳入故障测试。
        if let mock = ProcessInfo.processInfo.environment["CLAUDE_GUARD_TEST_MOCK"], !mock.isEmpty {
            return path == mock ? .desktop : nil
        }
        let p = path.lowercased()
        if p.hasPrefix("/applications/claude.app/contents/") { return .desktop }
        // Claude Desktop 内置的 Claude Code（Desktop 的 Code 标签页）是 Desktop 的子进程，关闭 Desktop 时会一起结束，
        // 所以归到 Desktop，跟着“管理 Claude Desktop”开关走。
        if p.contains("/library/application support/claude/claude-code/") { return .desktop }
        if p.contains("/.local/share/claude/versions/") { return .code }
        if p.contains("/.claude/local/") { return .code }
        if p.hasSuffix("/.local/bin/claude") { return .code }
        if p.contains("/caskroom/claude-code/") { return .code }
        let name = (p as NSString).lastPathComponent
        if name == "node" || name == "bun" {
            // npm 安装的 Claude Code 是 `node …/@anthropic-ai/claude-code/cli.js`。
            if argv().contains("@anthropic-ai/claude-code") { return .code }
        }
        let env = ProcessInfo.processInfo.environment
        if let mock = env["CLAUDE_GUARD_TEST_MOCK"], !mock.isEmpty, path.hasPrefix(mock) {
            return env["CLAUDE_GUARD_TEST_MOCK_APP"] == "code" ? .code : .desktop
        }
        return nil
    }

    public static func find() -> [ClaudeProcessInfo] {
        let all = ProcScanner.all()
        var found: [ClaudeProcessInfo] = []
        for process in all {
            guard let app = classify(path: process.path, argv: { ProcScanner.argv(pid: process.pid) }) else { continue }
            found.append(ClaudeProcessInfo(pid: process.pid, ppid: process.ppid, path: process.path,
                                           isRoot: true, app: app, startTime: process.startTime))
        }
        let pids = Set(found.map(\.pid))
        for index in found.indices {
            // Desktop 的 Helper 进程父进程也是 Claude；只有最外层算“本体”的主进程。
            found[index].isRoot = !pids.contains(found[index].ppid)
        }
        return found.sorted { $0.pid < $1.pid }
    }
}

/// TUN 模式下，mihomo 要等上游拨号成功才把连接放进 /connections，而 Claude 那边的 socket
/// 早已 ESTABLISHED。远端连接建立可能需要 1 秒以上。旧代码第一眼对不上就判“不在 Clash → 直连”，
/// enforce 时会把 Claude 误杀。只有持续对不上超过 grace 秒的 socket 才上报。
public final class UnmatchedSocketTracker {
    public let grace: TimeInterval
    private var firstSeen: [String: Date] = [:]
    private var current = Set<String>()

    public init(grace: TimeInterval = 5) {
        self.grace = grace
    }

    /// 记录本轮未匹配的 socket；持续未匹配超过 grace 时返回 true。
    func confirm(_ key: String, now: Date = Date()) -> Bool {
        current.insert(key)
        let since = firstSeen[key] ?? now
        firstSeen[key] = since
        return now.timeIntervalSince(since) >= grace
    }

    func finishRound() {
        // 本轮已匹配或已关闭的 socket 重新计时。
        firstSeen = firstSeen.filter { current.contains($0.key) }
        current = []
    }
}

public enum ProcessAuditor {
    public static func audit(processes: [ClaudeProcessInfo],
                             connections: [ConnectionInfo],
                             group: String = RuleAuditor.groupName,
                             approvedLeaf: String?,
                             mode: AuditMode,
                             unmatched: UnmatchedSocketTracker? = nil) -> [TrafficFinding] {
        defer { unmatched?.finishRound() }
        guard !processes.isEmpty else { return [] }
        var findings: [TrafficFinding] = []
        var seen = Set<String>()

        for process in processes {
            for socket in ProcScanner.sockets(pid: process.pid) {
                guard socket.remotePort != 0 else { continue }
                guard !socket.remoteAddr.isEmpty else { continue }
                guard socket.remoteAddr != "0.0.0.0" && socket.remoteAddr != "::" else { continue }
                if socket.proto == IPPROTO_TCP && socket.state != 4 { continue }

                // With the system proxy enabled, Claude connects to 127.0.0.1:7897.
                // The useful destination only exists in Clash's connection table, so
                // match it by the app's local source port instead of skipping loopback.
                let loopback = socket.remoteAddr == "127.0.0.1" || socket.remoteAddr == "::1"
                var connection: ConnectionInfo?
                // 端口号只在同一个本地地址内唯一：TUN 连接（198.18.0.1）和系统代理连接（127.0.0.1）
                // 可能用到同一个源端口，必须连 sourceIP 一起比，否则会把别的 App 的连接算到 Claude 头上。
                if loopback {
                    let candidates = connections.filter {
                        $0.sourceIP == socket.localAddr &&
                        Int($0.sourcePort) == Int(socket.localPort) && !$0.host.isEmpty
                    }
                    connection = candidates.first { ClaudeDomainCatalog.isClaudeOrTelemetry($0.host) }
                        ?? candidates.first
                    if connection == nil { continue }
                } else {
                    connection = connections.first {
                        $0.sourceIP == socket.localAddr &&
                        Int($0.sourcePort) == Int(socket.localPort) &&
                        (Int($0.destinationPort) == Int(socket.remotePort) || $0.destinationPort == 0)
                    }
                    if connection == nil, let unmatched,
                       !ClaudeDomainCatalog.isPrivateAddress(socket.remoteAddr),
                       !unmatched.confirm(socket.id) {
                        continue
                    }
                }

                let host = (connection?.host.isEmpty == false ? connection!.host : socket.remoteAddr)
                let remoteText: String
                if let connection, !connection.destinationIP.isEmpty {
                    remoteText = connection.destinationIP
                } else if let connection, !connection.remoteDestination.isEmpty {
                    remoteText = connection.remoteDestination
                } else if loopback {
                    // 代理连接在拨号完成前 Clash 还没有目标 IP；不能退回 127.0.0.1，
                    // 否则会被当成内网地址判为“本地”，把走了 DIRECT 的国外连接也放过去。
                    remoteText = ""
                } else {
                    remoteText = socket.remoteAddr
                }
                let port = connection.flatMap { $0.destinationPort > 0 ? $0.destinationPort : nil }
                    ?? Int(socket.remotePort)
                let chains = connection?.chains ?? []
                let chainText = chains.isEmpty ? "不在 Clash" : chains.joined(separator: " → ")
                let direct = chains.contains("DIRECT") || (connection == nil && !loopback)
                let ruleText = [connection?.rule, connection?.rulePayload]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")

                let (verdict, note) = classifyDestination(host: host, remote: remoteText, chains: chains, group: group,
                                                         approvedLeaf: approvedLeaf, mode: mode,
                                                         direct: direct, domesticRule: ruleIsCN(connection))

                let id = "\(process.pid)-\(host)-\(port)"
                guard seen.insert(id).inserted else { continue }
                findings.append(TrafficFinding(
                    id: id,
                    pid: process.pid,
                    process: process.shortName,
                    host: host,
                    remote: remoteText,
                    port: port,
                    chain: chainText,
                    rule: ruleText,
                    verdict: verdict,
                    note: note
                ))
            }
        }
        // 旧比较器在“非 violation 的不同 verdict”之间不满足严格弱序，列表顺序每轮都可能跳。
        return findings.sorted { lhs, rhs in
            if lhs.verdict != rhs.verdict { return rank(lhs.verdict) < rank(rhs.verdict) }
            if lhs.host != rhs.host { return lhs.host < rhs.host }
            if lhs.pid != rhs.pid { return lhs.pid < rhs.pid }
            return lhs.port < rhs.port
        }
    }

    public static func classifyDestination(host: String, remote: String, chains: [String],
                                           group: String = RuleAuditor.groupName,
                                           approvedLeaf: String?, mode: AuditMode, direct: Bool,
                                           domesticRule: Bool = false) -> (verdict: Verdict, note: String) {
        let ai = chains.contains(group) &&
            (approvedLeaf?.isEmpty != false || chains.contains(approvedLeaf!))
        if ClaudeDomainCatalog.isClaudeOrTelemetry(host) && !ai {
            return (.violation, "Claude 流量没有走 AI 节点")
        }
        if ClaudeDomainCatalog.isExternalService(host) {
            return (.allowedExternal, "GitHub 服务，遵循 Clash 分流")
        }
        if ClaudeDomainCatalog.isDomesticDomain(host) || ClaudeDomainCatalog.isPrivateAddress(remote) || domesticRule {
            return (.allowedDomestic, "本地或内网地址")
        }
        if ai { return (.ok, "通过 AI 节点") }
        if direct { return (.violation, "国外目标走了直连") }
        if mode == .strict { return (.violation, "严格模式：国外目标走了其他节点") }
        return (.warning, "国外目标走了其他节点")
    }

    private static func rank(_ verdict: Verdict) -> Int {
        switch verdict {
        case .violation: return 0
        case .warning: return 1
        case .ok: return 2
        case .allowedDomestic: return 3
        case .allowedExternal: return 4
        }
    }

    private static func ruleIsCN(_ connection: ConnectionInfo?) -> Bool {
        guard let connection else { return false }
        let rule = connection.rule.lowercased()
        let payload = connection.rulePayload.lowercased()
        if rule.contains("geoip") && payload == "cn" { return true }
        if rule.contains("domainsuffix") && payload == "cn" { return true }
        if rule.contains("domainkeyword") && payload == "-cn" { return true }
        return false
    }
}

public enum ClaudeKiller {
    /// 关闭指定的 Claude 进程及其所有子进程。
    /// 每个 pid 都和启动时间一起核对：扫描到关闭之间 pid 可能已被别的进程复用，旧代码会直接误杀。
    @discardableResult
    public static func terminate(_ processes: [ClaudeProcessInfo]) -> [Int32] {
        guard !processes.isEmpty else { return [] }
        let all = ProcScanner.all()
        let live = Dictionary(all.map { ($0.pid, $0.startTime) }, uniquingKeysWith: { a, _ in a })
        var children: [Int32: [Int32]] = [:]
        for process in all { children[process.ppid, default: []].append(process.pid) }

        var targets: [Int32: UInt64] = [:]
        var queue: [Int32] = []
        for process in processes {
            guard let start = live[process.pid], process.startTime == 0 || start == process.startTime else { continue }
            if targets[process.pid] == nil {
                targets[process.pid] = start
                queue.append(process.pid)
            }
        }
        while let pid = queue.popLast() {
            for child in children[pid] ?? [] where targets[child] == nil {
                guard let start = live[child] else { continue }
                targets[child] = start
                queue.append(child)
            }
        }
        guard !targets.isEmpty else { return [] }

        func stillSame(_ pid: Int32, _ start: UInt64) -> Bool {
            ProcScanner.startTime(pid: pid) == start
        }
        var signaled = Set<Int32>()
        for (pid, start) in targets where stillSame(pid, start) {
            if kill(pid, SIGTERM) == 0 { signaled.insert(pid) }
        }
        // Bounded grace period on a monotonic clock; signal-resistant processes cannot stall monitoring.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.15
        while ProcessInfo.processInfo.systemUptime < deadline,
              targets.contains(where: { stillSame($0.key, $0.value) }) {
            Thread.sleep(forTimeInterval: 0.005)
        }
        for (pid, start) in targets where stillSame(pid, start) {
            if kill(pid, SIGKILL) == 0 { signaled.insert(pid) }
        }
        return signaled.sorted()
    }
}
