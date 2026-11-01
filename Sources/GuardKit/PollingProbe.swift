import Foundation

/// 读取失败只能证明监测暂不可用；持续时间与重试次数均不能证明代理已经失效。
public struct ReadFailureTracker {
    private var firstFailure: TimeInterval?
    public private(set) var consecutiveFailures = 0

    public init() {}

    public mutating func succeeded() {
        firstFailure = nil
        consecutiveFailures = 0
    }

    public mutating func failed(at now: TimeInterval) {
        if firstFailure == nil { firstFailure = now }
        consecutiveFailures += 1
    }

    public func severity(at now: TimeInterval) -> Severity {
        firstFailure == nil ? .ok : .warning
    }

    public func failureDuration(at now: TimeInterval) -> TimeInterval {
        firstFailure.map { max(0, now - $0) } ?? 0
    }
}

struct ProbeReading<Value> {
    var value: Value?
    var severity: Severity
    var detail: String
    var observedAt: TimeInterval?

    /// 缓存可以显示，但失效或过期的读数不能成为新的自动关闭依据。
    func confirmedSeverity(_ result: Severity) -> Severity {
        severity == .ok ? result : .warning
    }
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
        queue = DispatchQueue(label: "com.local.claudeguard.probe.\(name)", qos: .userInitiated)
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
            let duration = Int(failures.failureDuration(at: now))
            return ProbeReading(value: value, severity: failures.severity(at: now),
                                detail: "\(error)\(previous)；连续失败 \(failures.consecutiveFailures) 次，持续 \(duration) 秒；状态未确认，继续重试（不会仅因此关闭应用）",
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

    mutating func unavailable(_ id: String) -> Severity {
        counts[id] = nil
        observations[id] = nil
        return .warning
    }

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
