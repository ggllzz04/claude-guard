import Foundation

/// 读取失败与已确认的异常分开：短暂忙碌只提示，长期失去监测能力才关闭。
public struct ReadFailureTracker {
    public static let grace: TimeInterval = 15
    private var firstFailure: TimeInterval?
    private var failures = 0

    public init() {}

    public mutating func succeeded() {
        firstFailure = nil
        failures = 0
    }

    public mutating func failed(at now: TimeInterval) {
        if firstFailure == nil { firstFailure = now }
        failures += 1
    }

    public func severity(at now: TimeInterval) -> Severity {
        guard let firstFailure else { return .ok }
        return failures >= 3 && now - firstFailure >= Self.grace ? .critical : .warning
    }
}

struct ProbeReading<Value> {
    var value: Value?
    var severity: Severity
    var detail: String
    var observedAt: TimeInterval?
}

/// 每种状态最多一个在途请求；重探测不会排队，前台检查只取已完成的结果。
final class PollingProbe<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let interval: TimeInterval
    private let load: () throws -> Value
    private var running = false
    private var finished: TimeInterval?
    private var succeeded: TimeInterval?
    private var value: Value?
    private var error: String?
    private var failures = ReadFailureTracker()

    init(_ name: String, interval: TimeInterval, load: @escaping () throws -> Value) {
        queue = DispatchQueue(label: "com.local.claudeguard.probe.\(name)", qos: .default)
        self.interval = interval
        self.load = load
    }

    func read() -> ProbeReading<Value> {
        lock.lock()
        defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if !running && (finished == nil || now - finished! >= interval) {
            running = true
            queue.async { [weak self] in
                guard let self else { return }
                let result = Result { try self.load() }
                self.lock.lock()
                defer { self.lock.unlock() }
                let now = ProcessInfo.processInfo.systemUptime
                self.finished = now
                self.running = false
                switch result {
                case .success(let value):
                    self.value = value
                    self.succeeded = now
                    self.error = nil
                    self.failures.succeeded()
                case .failure(let error):
                    self.error = error.localizedDescription
                    self.failures.failed(at: now)
                }
            }
        }
        if let error {
            let previous = succeeded.map { "；上次成功于 \(Int(max(0, now - $0))) 秒前" } ?? ""
            let severity = failures.severity(at: now)
            return ProbeReading(value: value, severity: severity,
                                detail: "\(error)\(previous)\(severity == .critical ? "；持续无法确认保护状态" : "；正在重试")",
                                observedAt: succeeded)
        }
        let stale = succeeded.map { now - $0 > max(15, interval * 3) } ?? false
        return ProbeReading(value: value, severity: value == nil || stale ? .warning : .ok,
                            detail: value == nil ? "正在读取状态" : (stale ? "状态已过期，正在重新读取" : ""), observedAt: succeeded)
    }
}

/// 本地观测到的故障需跨两轮确认，恢复即清零；读失败不算确认故障。
struct RiskDebouncer {
    private var counts: [String: Int] = [:]
    private var observations: [String: TimeInterval] = [:]

    mutating func severity(_ id: String, failed: Bool,
                           observedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Severity {
        guard failed else { counts[id] = nil; return .ok }
        if observations[id] != observedAt {
            observations[id] = observedAt
            counts[id, default: 0] += 1
        }
        return counts[id, default: 0] >= 2 ? .critical : .warning
    }
}
