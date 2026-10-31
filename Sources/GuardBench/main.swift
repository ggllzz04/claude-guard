import Foundation
import GuardKit

if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--api-check" {
    do {
        let path = CommandLine.arguments[2]
        guard path.hasPrefix("/private/tmp/") || path.hasPrefix("/tmp/") else { exit(64) }
        let endpoint = CommandLine.arguments[3]
        let timeout = Double(CommandLine.arguments[4]) ?? 0.5
        let client = try ClashClient(socketPath: path, timeout: timeout)
        switch endpoint {
        case "/configs": _ = try client.configs()
        case "/proxies": _ = try client.proxies()
        case "/rules": _ = try client.rules()
        default: _ = try UnixHTTPClient(socketPath: path).get(endpoint, timeout: timeout)
        }
        print("PASS: \(endpoint)")
        exit(0)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}

if CommandLine.arguments.contains("--self-test") {
    func require(_ condition: Bool, _ message: String) {
        if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
        print("PASS: \(message)")
    }
    require(ClaudeDomainCatalog.isClaudeOrTelemetry("api.anthropic.com"), "Claude domain")
    require(!ClaudeDomainCatalog.isClaudeOrTelemetry("anthropic.com.attacker.test"), "Domain suffix boundary")
    require(ClaudeLocator.classify(path: "/Applications/Claude.app/Contents/MacOS/Claude", argv: { "" }) == .desktop, "Desktop scope")
    require(ClaudeLocator.classify(path: "/usr/bin/curl", argv: { "" }) == nil, "Child tools excluded")
    require(!ClaudeDomainCatalog.isDomesticDomain("service.cn.attacker.test"), "Domestic domain boundary")
    require(!GuardSettings.default.manageCode && GuardSettings.default.manageDesktop, "Management defaults")
    require(!GuardSettings.default.enforce, "First install starts in observation mode")
    var reads = ReadFailureTracker()
    reads.failed(at: 100)
    reads.failed(at: 101)
    reads.failed(at: 102)
    require(reads.severity(at: 114.9) == .warning, "Transient read failures stay yellow throughout the grace period")
    require(reads.severity(at: 115) == .critical, "Persistent blindness requires both duration and repeated failures")
    reads.succeeded()
    reads.failed(at: 200)
    require(reads.severity(at: 300) == .warning, "A single failure after recovery cannot inherit an old critical state")
    let healthy = GuardCheck(id: "tun", title: "TUN", detail: "已就绪", severity: .ok, icon: "network")
    let warning = GuardCheck(id: "audit", title: "连接审计", detail: "其他出口", severity: .warning, icon: "eye")
    let critical = GuardCheck(id: "tun", title: "TUN", detail: "未开启", severity: .critical, icon: "network")
    require(GuardState.evaluate(checks: [healthy, warning], mode: .root, enforce: false) == .attention,
            "Observation mode must not hide a yellow warning")
    let finding = TrafficFinding(id: "external", pid: 0, process: "fixture", host: "external.example", remote: "1.1.1.1",
                                 port: 443, chain: "其他节点", rule: "MATCH", verdict: .warning, note: "国外目标走了其他节点")
    var oldSnapshot = Snapshot(state: .protected, checks: [healthy], findings: [finding],
                               settings: GuardSettings(enforce: true), daemonMode: .root)
    require(oldSnapshot.evaluatedState == .attention, "Connection warning overrides an older daemon's green state")
    oldSnapshot.findings[0].verdict = .violation
    require(oldSnapshot.evaluatedState == .attention, "Audit violations stay yellow and never escalate enforcement")
    for enforcing in [false, true] {
        oldSnapshot.settings.enforce = enforcing
        oldSnapshot.checks = [critical, warning]
        require(oldSnapshot.evaluatedState == .blocked, "Critical risk stays red with protection \(enforcing ? "on" : "off")")
        oldSnapshot.checks = [healthy, warning]
        require(oldSnapshot.evaluatedState == .attention, "Recovery from red retains remaining yellow warnings")
        oldSnapshot.checks = [healthy]
        oldSnapshot.findings = []
        require(oldSnapshot.evaluatedState == (enforcing ? .protected : .disabled), "Cleared warnings restore the actual protection state")
    }
    func destination(_ host: String, chains: [String] = ["Other", "Provider"], mode: AuditMode = .standard) -> Verdict {
        ProcessAuditor.classifyDestination(host: host, remote: "1.1.1.1", chains: chains, approvedLeaf: "Approved",
                                           mode: mode, direct: chains.contains("DIRECT")).verdict
    }
    for host in ["api.github.com", "codeload.github.com", "raw.githubusercontent.com", "release-assets.githubusercontent.com", "github.githubassets.com", "API.GITHUB.COM."] {
        require(destination(host) == .allowedExternal && destination(host, chains: ["DIRECT"], mode: .strict) == .allowedExternal,
                "GitHub follows normal Clash routing: \(host)")
    }
    require(destination("github.com.attacker.test") == .warning && destination("fakegithub.com") == .warning,
            "External service exceptions require a domain boundary")
    require(destination("api.anthropic.com") == .violation && destination("o123.ingest.sentry.io") == .violation,
            "Claude and telemetry still require AI routing")
    require(destination("api.anthropic.com", chains: ["Approved", "🤖 AI"]) == .ok,
            "Claude through the approved AI node stays healthy")
    require(destination("external.example") == .warning && destination("external.example", chains: ["DIRECT"]) == .violation,
            "Unrecognized destinations retain existing audit behavior")
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["30"]
    try child.run()
    let pid = child.processIdentifier
    guard let start = ProcScanner.startTime(pid: pid) else { fatalError("Missing child identity") }
    let wrong = ClaudeProcessInfo(pid: pid, ppid: getpid(), path: "/bin/sleep", isRoot: true, startTime: start + 1)
    require(ClaudeKiller.terminate([wrong]).isEmpty && child.isRunning, "Reused PID identity cannot be killed")
    let correct = ClaudeProcessInfo(pid: pid, ppid: getpid(), path: "/bin/sleep", isRoot: true, startTime: start)
    require(ClaudeKiller.terminate([correct]).contains(pid), "Exact mock identity terminated")
    child.waitUntilExit()
    require(child.terminationReason == .uncaughtSignal, "Process really exited")
    let folder = URL(fileURLWithPath: "/private/tmp/cg-regression-" + UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let mock = folder.appendingPathComponent("GuardMock")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("GuardMock"), to: mock)
    let fixture = Process()
    fixture.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    fixture.arguments = ["--safety-fixture", folder.path]
    fixture.environment = ProcessInfo.processInfo.environment.merging([
        "CLAUDE_GUARD_TEST_MOCK": mock.path,
        "CLAUDE_GUARD_CLASH_SOCKET": folder.appendingPathComponent("absent.sock").path
    ], uniquingKeysWith: { _, new in new })
    try fixture.run()
    fixture.waitUntilExit()
    try? FileManager.default.removeItem(at: folder)
    require(fixture.terminationStatus == 0, "Safety fixture passes")
    exit(0)
}

if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--safety-fixture" {
    func require(_ condition: Bool, _ message: String) {
        if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
        print("PASS: \(message)")
    }
    let folder = URL(fileURLWithPath: CommandLine.arguments[2])
    let mock = folder.appendingPathComponent("GuardMock")
    let managed = Process()
    managed.executableURL = mock
    managed.arguments = ["--hold"]
    managed.standardOutput = FileHandle.nullDevice
    try managed.run()
    Thread.sleep(forTimeInterval: 0.05)
    require(ClaudeLocator.find().contains { $0.pid == managed.processIdentifier }, "Isolated fixture is discoverable")
    let guardService = GuardService(mode: .root, configDir: folder.path)
    var prefs = GuardSettings.default
    prefs.enforce = true
    prefs.manageDesktop = false
    let unmanaged = guardService.updateSettings(prefs)
    require(unmanaged.state == .attention && managed.isRunning, "Initial missing API is uncertainty, not a confirmed outage")
    prefs.manageDesktop = true
    prefs.enforce = false
    _ = guardService.updateSettings(prefs)
    require(managed.isRunning, "Protection off never kills")
    let preview = GuardService(mode: .test, configDir: folder.path)
    prefs.enforce = true
    let test = preview.updateSettings(prefs)
    require(!test.settings.enforce && managed.isRunning, "Test daemon cannot enforce")
    var closed = guardService.updateSettings(prefs)
    require(managed.isRunning && closed.state != .blocked, "Enabling protection does not kill on a transient read failure")
    let deadline = ProcessInfo.processInfo.systemUptime + 19
    while managed.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
        Thread.sleep(forTimeInterval: 0.1)
        closed = guardService.refresh()
    }
    if managed.isRunning { managed.terminate(); require(false, "Persistent unreadable state must eventually enforce") }
    managed.waitUntilExit()
    require(closed.events.contains { $0.title.contains("不满足要求，关闭了") }, "Close activity states reason and action")
    require(closed.processes.isEmpty, "Managed mock really closed on critical risk")
    exit(0)
}

// 仅测试宿主：必须显式指定 mock 可执行文件和独立配置目录。
guard CommandLine.arguments.count == 2,
      let mock = ProcessInfo.processInfo.environment["CLAUDE_GUARD_TEST_MOCK"],
      mock.hasPrefix("/private/tmp/") || mock.hasPrefix("/tmp/"),
      let socket = ProcessInfo.processInfo.environment["CLAUDE_GUARD_CLASH_SOCKET"],
      socket.hasPrefix("/tmp/") || socket.hasPrefix("/private/tmp/") else { exit(64) }
let service = GuardService(mode: .root, configDir: CommandLine.arguments[1])
while true {
    let start = ProcessInfo.processInfo.systemUptime
    let snapshot = service.refresh()
    print(GuardJSON.string(snapshot))
    fflush(stdout)
    Thread.sleep(forTimeInterval: max(0, snapshot.settings.pollInterval - (ProcessInfo.processInfo.systemUptime - start)))
}
