import Foundation
import GuardKit

@main
struct GuardDaemonMain {
    static func main() {
        var testMode = false
        var once = false
        var preserveNetwork = false
        var socketOverride: String?
        var configOverride: String?

        var args = Array(CommandLine.arguments.dropFirst())
        while let arg = args.first {
            args.removeFirst()
            switch arg {
            case "--test":
                testMode = true
            case "--once":
                once = true
            case "--preserve-network":
                preserveNetwork = true
            case "--socket":
                socketOverride = args.first
                if !args.isEmpty { args.removeFirst() }
            case "--config-dir":
                configOverride = args.first
                if !args.isEmpty { args.removeFirst() }
            case "--help", "-h":
                print("""
                Usage: GuardDaemon [--test] [--once] [--socket PATH] [--config-dir PATH]
                  --test       测试模式：用户态启动，不杀进程，不读 PF
                  --once       只检查一次，输出 JSON 后退出
                  --preserve-network  保留现有网络规则，启动时不启用或重载 PF
                """)
                exit(0)
            default:
                break
            }
        }

        if !testMode && geteuid() != 0 {
            fputs("GuardDaemon 需要 root 运行；本地调试请加 --test\n", stderr)
            exit(1)
        }

        let mode: DaemonMode = testMode ? .test : .root
        let configDir = configOverride ?? (testMode ? NSHomeDirectory() + "/Library/Application Support/Claude Guard" : "/Library/Application Support/Claude Guard")
        let socketPath = socketOverride ?? (testMode ? configDir + "/guard.sock" : "/var/run/com.local.claudeguard.sock")

        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        let service = GuardService(mode: mode, configDir: configDir)

        if mode == .root && !once && !preserveNetwork {
            _ = Shell.run("/sbin/pfctl", ["-E"], timeout: 2)
            let anchor = "/etc/pf.anchors/com.local.claudeguard"
            if FileManager.default.fileExists(atPath: anchor) {
                _ = Shell.run("/sbin/pfctl", ["-a", "com.local.claudeguard", "-f", anchor], timeout: 2)
            }
        }

        if once {
            let snapshot = service.refresh()
            let output = GuardJSON.string(snapshot)
            print(output)
            fflush(stdout)
            exit(snapshot.state == .blocked ? 2 : 0)
        }

        let queue = DispatchQueue(label: "com.local.claudeguard.daemon.timer")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        func schedule(_ pollInterval: Double, delay: Double) {
            let interval = max(0.25, pollInterval)
            timer.schedule(deadline: .now() + delay, repeating: interval, leeway: .milliseconds(10))
        }
        schedule(service.currentSettings.pollInterval, delay: 0.2)
        timer.setEventHandler {
            _ = service.refresh()
        }

        let server = UnixSocketServer(path: socketPath) { request in
            switch request.command {
            case "status":
                return IPCResponse(id: request.id, snapshot: service.currentSnapshot(), settings: service.currentSettings)
            case "recheck":
                service.requestEgressProbe()
                return IPCResponse(id: request.id, snapshot: service.refresh(), settings: service.currentSettings)
            case "block":
                return IPCResponse(id: request.id, snapshot: service.blockClaude(), settings: service.currentSettings)
            case "approve":
                return IPCResponse(id: request.id, snapshot: service.approveCurrentNode(), settings: service.currentSettings)
            case "settings":
                guard let json = request.payload?["json"],
                      let data = json.data(using: .utf8),
                      let settings = try? GuardJSON.decoder.decode(GuardSettings.self, from: data) else {
                    return IPCResponse(id: request.id, ok: false, error: "settings JSON 无效")
                }
                let snapshot = service.updateSettings(settings)
                // 旧代码只在启动时读一次轮询间隔，改了“检查频率”要重启守护才生效。
                schedule(snapshot.settings.pollInterval, delay: snapshot.settings.pollInterval)
                return IPCResponse(id: request.id, snapshot: snapshot, settings: snapshot.settings)
            case "events":
                return IPCResponse(id: request.id, snapshot: service.currentSnapshot(), events: service.recentEvents())
            case "findings":
                return IPCResponse(id: request.id, snapshot: service.currentSnapshot(), findings: service.recentFindings())
            case "ping":
                return IPCResponse(id: request.id, snapshot: service.currentSnapshot())
            case "shutdown":
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
                return IPCResponse(id: request.id, ok: true)
            default:
                return IPCResponse(id: request.id, ok: false, error: "未知命令: \(request.command)")
            }
        }

        do {
            try server.start()
        } catch {
            fputs("启动 IPC 失败: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        timer.resume()

        signal(SIGPIPE, SIG_IGN)
        let signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        signalSource.setEventHandler {
            server.stop()
            exit(0)
        }
        signalSource.resume()
        signal(SIGTERM, SIG_IGN)

        print("Claude Guard daemon started (\(mode.rawValue)) socket=\(socketPath)")
        fflush(stdout)
        RunLoop.main.run()
    }
}
