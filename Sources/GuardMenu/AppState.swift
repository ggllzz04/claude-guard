import Foundation
import Combine
import GuardKit

private struct RefreshResult: Sendable {
    var snapshot: Snapshot
    var connected: Bool
    var error: String?
}

@MainActor
final class AppState: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var selection: SidebarItem = .overview
    @Published var daemonConnected = false
    @Published var lastError: String?
    @Published var showError = false
    /// 正在等守护返回的命令（封锁 / 批准 / 保存）；用来禁用按钮，避免重复点击。
    @Published var pendingCommand: String?

    var onStateChange: ((Snapshot) -> Void)?

    // 设置草稿不再放在这里：它是 @Published，拨一下开关、拖一下滑块就会让所有页面一起重绘，
    // 这是设置页卡顿的原因。现在草稿由 SettingsView 自己持有，保存时才提交。

    // 不用 @Published：它不显示在界面上，每轮翻转两次会让整个窗口白白重绘两次。
    private var isRefreshing = false
    private var requestSeq = 0
    private var appliedSeq = 0
    private var loopTask: Task<Void, Never>?
    private var readOnlyService: GuardService?
    private let socketCandidates: [String]

    init() {
        // root 守护优先；用户目录下的 socket 只有本地 --test 守护才会有。
        var candidates = [
            "/var/run/com.local.claudeguard.sock",
            GuardPaths.socketPath,
            NSHomeDirectory() + "/Library/Application Support/Claude Guard/guard.sock",
        ]
        var seen = Set<String>()
        candidates = candidates.filter { seen.insert($0).inserted }
        self.socketCandidates = candidates
    }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                // status 只读守护的缓存快照，数据没变时不会触发重绘，1 秒一轮的成本很低。
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    func refresh() async {
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await fetch(command: "status")
    }

    func recheck() {
        // “刷新”按钮要求守护立即重新检查，而不是返回上一轮缓存。
        Task { await fetch(command: "recheck") }
    }

    private func fetch(command: String) async {
        requestSeq += 1
        let seq = requestSeq
        let candidates = socketCandidates
        let readOnly = readOnlyService ?? GuardService(mode: .readOnly)
        readOnlyService = readOnly
        let result = await Task.detached(priority: .userInitiated) { () -> RefreshResult in
            for path in candidates {
                guard FileManager.default.fileExists(atPath: path) else { continue }
                let client = GuardClient(socketPath: path)
                if let response = try? client.request(command), let snapshot = response.snapshot {
                    return RefreshResult(snapshot: snapshot, connected: true, error: response.error)
                }
            }
            let snapshot = readOnly.refresh()
            return RefreshResult(snapshot: snapshot, connected: false, error: snapshot.lastError)
        }.value

        // 轮询和手动刷新可能同时在途；晚发出的请求先回来时，不能被早发出的旧结果覆盖。
        guard seq > appliedSeq else { return }
        appliedSeq = seq
        if result.connected != daemonConnected { daemonConnected = result.connected }
        if result.error != lastError { lastError = result.error }
        apply(result.snapshot)
    }

    /// 只有内容真正变化时才发布；timestamp 每轮都变，比较时忽略。
    private func apply(_ incoming: Snapshot) {
        // 兼容仍在运行的旧守护：不能让它返回的旧状态盖住当前检查/连接里的告警。
        var new = incoming
        new.state = new.evaluatedState
        if let old = snapshot {
            var comparable = new
            comparable.timestamp = old.timestamp
            if comparable == old { return }
        }
        snapshot = new
        onStateChange?(new)
    }

    func blockClaude() {
        send("block", failure: "封锁失败")
    }

    func approveCurrentNode() {
        send("approve", failure: "批准失败")
    }

    /// 由设置页传入它自己的草稿；保存成功后设置页会按守护返回的快照重新同步草稿。
    func saveSettings(_ settings: GuardSettings, completion: ((Bool) -> Void)? = nil) {
        guard let data = try? GuardJSON.encoder.encode(settings),
              let json = String(data: data, encoding: .utf8) else {
            completion?(false)
            return
        }
        send("settings", payload: ["json": json], failure: "保存失败", completion: completion)
    }

    /// 封锁 / 批准 / 保存共用：只读模式直接提示；同一时间只发一条命令。
    private func send(_ command: String, payload: [String: String]? = nil, failure: String,
                      completion: ((Bool) -> Void)? = nil) {
        guard daemonConnected else {
            lastError = "\(failure)：当前是预览模式，需要先安装守护进程。"
            showError = true
            completion?(false)
            return
        }
        guard pendingCommand == nil else {
            completion?(false)
            return
        }
        pendingCommand = command
        let candidates = socketCandidates
        Task {
            let response = await Task.detached(priority: .userInitiated) { () -> IPCResponse? in
                for path in candidates {
                    guard FileManager.default.fileExists(atPath: path) else { continue }
                    let client = GuardClient(socketPath: path)
                    if let response = try? client.request(command, payload: payload) { return response }
                }
                return nil
            }.value
            self.pendingCommand = nil
            if let response, response.ok, let snapshot = response.snapshot {
                self.applyCommandResult(snapshot)
                completion?(true)
            } else {
                self.lastError = "\(failure)：\(response?.error ?? "守护进程没有响应。")"
                self.showError = true
                completion?(false)
            }
        }
    }

    /// 封锁 / 批准 / 保存之后，守护返回的是最新快照：让在途的旧轮询结果作废。
    private func applyCommandResult(_ snapshot: Snapshot) {
        requestSeq += 1
        appliedSeq = requestSeq
        apply(snapshot)
    }
}
