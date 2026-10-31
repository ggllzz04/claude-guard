import Foundation
import CryptoKit

// MARK: - State

public enum GuardState: String, Codable, CaseIterable, Sendable {
    case protected
    case attention
    case blocked
    case disabled
    case unknown

    public var title: String {
        switch self {
        case .protected: return "已保护"
        case .attention: return "需要注意"
        case .blocked: return "严重风险"
        case .disabled: return "未启用"
        case .unknown: return "检查中"
        }
    }

    public var subtitle: String {
        switch self {
        case .protected: return "受管理客户端的流量经由你选择的 AI 节点"
        case .attention: return "发现检查或连接提示，请查看详情"
        case .blocked: return "流量可能绕过 Clash 直连"
        case .disabled: return "保护未开启，只观察不干预"
        case .unknown: return "正在检查…"
        }
    }

    /// 告警优先于保护开关；连接审计始终只升到黄色，不改变关闭策略。
    public static func evaluate(checks: [GuardCheck], findings: [TrafficFinding] = [],
                                mode: DaemonMode, enforce: Bool) -> GuardState {
        if checks.contains(where: { $0.severity == .critical }) { return .blocked }
        if checks.contains(where: { $0.severity == .warning }) ||
            findings.contains(where: { $0.verdict == .warning || $0.verdict == .violation }) {
            return .attention
        }
        guard !checks.isEmpty else { return .unknown }
        if mode != .root { return .attention }
        return enforce ? .protected : .disabled
    }
}

public enum Severity: String, Codable, CaseIterable, Comparable, Sendable {
    case ok
    case warning
    case critical

    private var rank: Int {
        switch self {
        case .ok: return 0
        case .warning: return 1
        case .critical: return 2
        }
    }

    public static func < (lhs: Severity, rhs: Severity) -> Bool {
        lhs.rank < rhs.rank
    }
}

public enum AuditMode: String, Codable, CaseIterable, Sendable {
    case standard
    case strict

    public var title: String {
        switch self {
        case .standard: return "标准"
        case .strict: return "严格"
        }
    }
}

public enum DaemonMode: String, Codable, Sendable {
    case root
    case test
    case readOnly

    public var title: String {
        switch self {
        case .root: return "守护中"
        case .test: return "测试模式"
        case .readOnly: return "预览模式"
        }
    }
}

// MARK: - Checks

public struct GuardCheck: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var severity: Severity
    public var icon: String

    public init(id: String, title: String, detail: String, severity: Severity, icon: String) {
        self.id = id
        self.title = title
        self.detail = detail
        self.severity = severity
        self.icon = icon
    }
}

// MARK: - Node

public struct NodeInfo: Codable, Equatable, Sendable {
    public var group: String
    public var name: String
    public var type: String
    public var delay: Int
    public var isLeaf: Bool
    public var chain: [String]
    public var fingerprint: String?
    public var approved: Bool
    public var dialerProxy: String?

    public init(group: String = "🤖 AI", name: String = "", type: String = "", delay: Int = 0,
                isLeaf: Bool = false, chain: [String] = [], fingerprint: String? = nil,
                approved: Bool = false, dialerProxy: String? = nil) {
        self.group = group
        self.name = name
        self.type = type
        self.delay = delay
        self.isLeaf = isLeaf
        self.chain = chain
        self.fingerprint = fingerprint
        self.approved = approved
        self.dialerProxy = dialerProxy
    }
}

// MARK: - Processes

public enum ClaudeApp: String, Codable, CaseIterable, Sendable {
    case desktop
    case code

    public var title: String {
        switch self {
        case .desktop: return "Claude Desktop"
        case .code: return "Claude Code"
        }
    }
}

public struct ClaudeProcessInfo: Identifiable, Codable, Equatable, Sendable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var ppid: Int32
    public var path: String
    public var isRoot: Bool
    public var app: ClaudeApp
    /// 进程启动时间（微秒）。关闭前用它核对 pid 没有被别的进程复用。
    public var startTime: UInt64

    public init(pid: Int32, ppid: Int32, path: String, isRoot: Bool,
                app: ClaudeApp = .desktop, startTime: UInt64 = 0) {
        self.pid = pid
        self.ppid = ppid
        self.path = path
        self.isRoot = isRoot
        self.app = app
        self.startTime = startTime
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = try c.decode(Int32.self, forKey: .pid)
        ppid = try c.decode(Int32.self, forKey: .ppid)
        path = try c.decode(String.self, forKey: .path)
        isRoot = try c.decode(Bool.self, forKey: .isRoot)
        app = try c.decodeIfPresent(ClaudeApp.self, forKey: .app) ?? .desktop
        startTime = try c.decodeIfPresent(UInt64.self, forKey: .startTime) ?? 0
    }

    public var shortName: String {
        if app == .desktop && !isRoot {
            return "Claude Desktop · \((path as NSString).lastPathComponent)"
        }
        return app.title
    }
}

// MARK: - Traffic

public enum Verdict: String, Codable, Sendable {
    case ok
    case allowedDomestic
    case allowedExternal
    case warning
    case violation

    public var title: String {
        switch self {
        case .ok: return "AI 节点"
        case .allowedDomestic: return "本地"
        case .allowedExternal: return "外部服务"
        case .warning: return "提示"
        case .violation: return "异常"
        }
    }
}

public struct TrafficFinding: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var time: Date
    public var pid: Int32
    public var process: String
    public var host: String
    public var remote: String
    public var port: Int
    public var chain: String
    public var rule: String
    public var verdict: Verdict
    public var note: String

    public init(id: String, time: Date = Date(), pid: Int32, process: String, host: String,
                remote: String, port: Int, chain: String, rule: String, verdict: Verdict, note: String) {
        self.id = id
        self.time = time
        self.pid = pid
        self.process = process
        self.host = host
        self.remote = remote
        self.port = port
        self.chain = chain
        self.rule = rule
        self.verdict = verdict
        self.note = note
    }
}

// MARK: - Events

public struct GuardEvent: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var time: Date
    public var severity: Severity
    public var title: String
    public var detail: String

    public init(id: String = UUID().uuidString, time: Date = Date(), severity: Severity,
                title: String, detail: String) {
        self.id = id
        self.time = time
        self.severity = severity
        self.title = title
        self.detail = detail
    }
}

// MARK: - Settings

public struct GuardSettings: Codable, Equatable, Sendable {
    public var auditMode: AuditMode
    public var webrtcStrict: Bool
    public var canaryEnabled: Bool
    public var notificationsEnabled: Bool
    public var pollInterval: Double
    public var approvedNodeName: String
    public var approvedNodeType: String
    public var approvedFingerprint: String?
    public var enforce: Bool
    /// 是否审计 / 关闭 Claude Desktop（含它内置的 Claude Code）。
    public var manageDesktop: Bool
    /// 是否审计 / 关闭命令行 Claude Code。它可能配置了第三方 API，默认不管。
    public var manageCode: Bool

    public init(auditMode: AuditMode = .standard,
                webrtcStrict: Bool = false,
                canaryEnabled: Bool = false,
                notificationsEnabled: Bool = true,
                pollInterval: Double = 0.5,
                approvedNodeName: String = "",
                approvedNodeType: String = "",
                approvedFingerprint: String? = nil,
                enforce: Bool = false,
                manageDesktop: Bool = true,
                manageCode: Bool = false) {
        self.auditMode = auditMode
        self.webrtcStrict = webrtcStrict
        self.canaryEnabled = canaryEnabled
        self.notificationsEnabled = notificationsEnabled
        self.pollInterval = pollInterval
        self.approvedNodeName = approvedNodeName
        self.approvedNodeType = approvedNodeType
        self.approvedFingerprint = approvedFingerprint
        self.enforce = enforce
        self.manageDesktop = manageDesktop
        self.manageCode = manageCode
    }

    /// 逐字段容错解码：旧版 settings.json 缺新字段时，合成的 Codable 会整体失败，
    /// 回退到默认值后已批准的节点指纹就丢了。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GuardSettings()
        auditMode = (try? c.decodeIfPresent(AuditMode.self, forKey: .auditMode)) ?? d.auditMode
        webrtcStrict = (try? c.decodeIfPresent(Bool.self, forKey: .webrtcStrict)) ?? d.webrtcStrict
        canaryEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .canaryEnabled)) ?? d.canaryEnabled
        notificationsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled)) ?? d.notificationsEnabled
        pollInterval = (try? c.decodeIfPresent(Double.self, forKey: .pollInterval)) ?? d.pollInterval
        approvedNodeName = (try? c.decodeIfPresent(String.self, forKey: .approvedNodeName)) ?? d.approvedNodeName
        approvedNodeType = (try? c.decodeIfPresent(String.self, forKey: .approvedNodeType)) ?? d.approvedNodeType
        approvedFingerprint = (try? c.decodeIfPresent(String.self, forKey: .approvedFingerprint)) ?? nil
        enforce = (try? c.decodeIfPresent(Bool.self, forKey: .enforce)) ?? d.enforce
        manageDesktop = (try? c.decodeIfPresent(Bool.self, forKey: .manageDesktop)) ?? d.manageDesktop
        manageCode = (try? c.decodeIfPresent(Bool.self, forKey: .manageCode)) ?? d.manageCode
    }

    public func manages(_ app: ClaudeApp) -> Bool {
        switch app {
        case .desktop: return manageDesktop
        case .code: return manageCode
        }
    }

    public static let `default` = GuardSettings()
}

// MARK: - Snapshot

public struct Snapshot: Codable, Equatable, Sendable {
    public var state: GuardState
    public var timestamp: Date
    public var checks: [GuardCheck]
    public var node: NodeInfo?
    public var egressIP: String?
    public var processes: [ClaudeProcessInfo]
    public var findings: [TrafficFinding]
    public var events: [GuardEvent]
    public var settings: GuardSettings
    public var clashVersion: String?
    public var daemonMode: DaemonMode
    public var lastError: String?
    public var protectedSince: Date?

    public var stateSubtitle: String {
        if state == .blocked {
            if daemonMode == .root && settings.enforce {
                return "流量可能绕过 Clash 直连，被管理的 Claude 会被立即关闭"
            }
            return "流量可能绕过 Clash 直连（保护未开启，不会关闭 Claude）"
        }
        if state == .attention && !settings.enforce {
            return "发现需要注意的问题；保护未开启，当前只观察"
        }
        return state.subtitle
    }

    public var evaluatedState: GuardState {
        GuardState.evaluate(checks: checks, findings: findings, mode: daemonMode, enforce: settings.enforce)
    }

    public init(state: GuardState = .unknown,
                timestamp: Date = Date(),
                checks: [GuardCheck] = [],
                node: NodeInfo? = nil,
                egressIP: String? = nil,
                processes: [ClaudeProcessInfo] = [],
                findings: [TrafficFinding] = [],
                events: [GuardEvent] = [],
                settings: GuardSettings = .default,
                clashVersion: String? = nil,
                daemonMode: DaemonMode = .readOnly,
                lastError: String? = nil,
                protectedSince: Date? = nil) {
        self.state = state
        self.timestamp = timestamp
        self.checks = checks
        self.node = node
        self.egressIP = egressIP
        self.processes = processes
        self.findings = findings
        self.events = events
        self.settings = settings
        self.clashVersion = clashVersion
        self.daemonMode = daemonMode
        self.lastError = lastError
        self.protectedSince = protectedSince
    }

    public var criticalCount: Int { checks.filter { $0.severity == .critical }.count }
    public var warningCount: Int { checks.filter { $0.severity == .warning }.count }
    public var isClaudeRunning: Bool { !processes.isEmpty }
}

// MARK: - Helpers

public enum GuardFormat {
    public static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // 每行事件渲染都会调用；DateFormatter 创建成本高，复用同一个实例（格式化是线程安全的）。
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    public static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    public static func dateTime(_ date: Date) -> String {
        dateTimeFormatter.string(from: date)
    }

    public static func relative(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 5 { return "刚刚" }
        if seconds < 60 { return "\(seconds) 秒前" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        return "\(seconds / 3600) 小时前"
    }

    public static func bytes(_ value: Int64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var v = Double(value)
        var i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        return String(format: "%.1f %@", v, units[i])
    }

    public static func sha256(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum GuardJSON {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static func string<T: Encodable>(_ value: T) -> String {
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
