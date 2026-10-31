import Foundation
import GuardKit

@main
struct GuardCLIMain {
    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())
        var json = false
        var socket: String?

        var filtered: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--json" {
                json = true
            } else if arg == "--socket", index + 1 < args.count {
                socket = args[index + 1]
                index += 1
            } else {
                filtered.append(arg)
            }
            index += 1
        }
        args = filtered

        let command = args.first ?? "status"
        let socketPath = socket ?? GuardCLIMain.defaultSocketPath
        let client = GuardClient(socketPath: socketPath)

        do {
            switch command {
            case "status":
                let response = try client.request("status")
                if json, let snapshot = response.snapshot {
                    print(GuardJSON.string(snapshot))
                } else {
                    printStatus(response.snapshot)
                }
            case "check", "recheck":
                let response = try client.request("recheck")
                if json, let snapshot = response.snapshot {
                    print(GuardJSON.string(snapshot))
                } else {
                    printStatus(response.snapshot)
                }
            case "block":
                let response = try client.request("block")
                if let error = response.error { fputs("\(error)\n", stderr) }
                if json, let snapshot = response.snapshot {
                    print(GuardJSON.string(snapshot))
                } else {
                    printStatus(response.snapshot)
                }
            case "approve":
                let response = try client.request("approve")
                if let error = response.error { fputs("\(error)\n", stderr) }
                if json, let snapshot = response.snapshot {
                    print(GuardJSON.string(snapshot))
                } else {
                    printStatus(response.snapshot)
                }
            case "events":
                let response = try client.request("events")
                if json {
                    print(GuardJSON.string(response.events ?? []))
                } else {
                    for event in response.events ?? [] {
                        print("[\(GuardFormat.dateTime(event.time))] \(event.severity.rawValue.uppercased()) \(event.title) — \(event.detail)")
                    }
                }
            case "findings":
                let response = try client.request("findings")
                if json {
                    print(GuardJSON.string(response.findings ?? []))
                } else {
                    for finding in response.findings ?? [] {
                        print("[\(GuardFormat.dateTime(finding.time))] \(finding.verdict.rawValue) \(finding.process) → \(finding.host):\(finding.port) \(finding.chain) — \(finding.note)")
                    }
                }
            case "help", "--help", "-h":
                print("""
                Usage: claude-guardctl [status|check|block|approve|events|findings] [--json] [--socket PATH]
                """)
            default:
                fputs("未知命令: \(command)\n", stderr)
                exit(1)
            }
        } catch {
            fputs("无法连接守护进程 (\(socketPath)): \(error.localizedDescription)\n", stderr)
            fputs("本地调试可先运行: GuardDaemon --test\n", stderr)
            exit(1)
        }
    }

    static var defaultSocketPath: String {
        let daemonSocket = "/var/run/com.local.claudeguard.sock"
        if FileManager.default.fileExists(atPath: daemonSocket) {
            return daemonSocket
        }
        return GuardPaths.socketPath
    }

    static func printStatus(_ snapshot: Snapshot?) {
        guard let snapshot else {
            print("没有状态")
            return
        }
        print("状态: \(snapshot.state.title) — \(snapshot.stateSubtitle)")
        print("模式: \(snapshot.daemonMode.title)  Clash: \(snapshot.clashVersion ?? "unknown")")
        if let node = snapshot.node {
            print("节点: \(node.name) [\(node.type)] \(node.isLeaf ? "leaf" : "group") \(node.delay)ms")
            if let fingerprint = node.fingerprint {
                print("指纹: \(fingerprint.prefix(16))… approved=\(node.approved)")
            }
        }
        print("Claude 进程: \(snapshot.processes.count)")
        for process in snapshot.processes.prefix(8) {
            print("  \(process.pid) \(process.shortName) \(process.path)")
        }
        print("检查:")
        for check in snapshot.checks {
            let mark = check.severity == .ok ? "✓" : (check.severity == .warning ? "!" : "✗")
            print("  \(mark) \(check.title): \(check.detail)")
        }
        if !snapshot.findings.isEmpty {
            print("连接审计:")
            for finding in snapshot.findings.prefix(10) {
                print("  \(finding.verdict.title) \(finding.process) → \(finding.host):\(finding.port) [\(finding.chain)] \(finding.note)")
            }
        }
    }
}
