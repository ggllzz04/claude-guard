import Foundation
import SystemConfiguration

public enum GuardPaths {
    public static var isRoot: Bool { geteuid() == 0 }

    public static var consoleUID: uid_t {
        var st = stat()
        if stat("/dev/console", &st) == 0, st.st_uid != 0 {
            return st.st_uid
        }
        if let sudo = ProcessInfo.processInfo.environment["SUDO_UID"], let value = uid_t(sudo) {
            return value
        }
        return getuid()
    }

    public static var consoleHome: String {
        if let pw = getpwuid(consoleUID) {
            return String(cString: pw.pointee.pw_dir)
        }
        return NSHomeDirectory()
    }

    public static var configDir: String {
        if isRoot {
            return "/Library/Application Support/Claude Guard"
        }
        return NSHomeDirectory() + "/Library/Application Support/Claude Guard"
    }

    public static var socketPath: String {
        if isRoot {
            return "/var/run/com.local.claudeguard.sock"
        }
        return configDir + "/guard.sock"
    }

    public static var profilePath: String {
        consoleHome + "/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml"
    }

    public static func clashSocket() -> String? {
        if let env = ProcessInfo.processInfo.environment["CLAUDE_GUARD_CLASH_SOCKET"], !env.isEmpty {
            return env
        }
        let uid = consoleUID
        let candidates = [
            "/var/run/clash-verge-service/users/\(uid)/verge-mihomo.sock",
            "/var/run/clash-verge-service/users/\(getuid())/verge-mihomo.sock",
            "/tmp/verge-mihomo.sock",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    public static func ensureConfigDir() throws {
        try FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
    }
}

public struct TailscaleInfo: Equatable, Sendable {
    public var installed: Bool
    public var running: Bool
    public var backendState: String
    public var exitNode: Bool
    public var ips: [String]
}

public struct SystemProxyEntry: Equatable, Sendable {
    public var kind: String
    public var host: String
    public var port: Int
}

public struct SystemProxyInfo: Equatable, Sendable {
    /// 已启用的 HTTP / HTTPS / SOCKS 代理，逐项分开（旧版把三者的 host/port 混在一起，只要一项对就算对）。
    public var entries: [SystemProxyEntry]
    public var pacEnabled: Bool
    public var readable: Bool

    public var enabled: Bool { !entries.isEmpty }
}

public struct PFCheck {
    /// PF 总开关。关掉时锚点规则还在，但不生效；旧版没查这一项。
    public var enabled: Bool
    /// 锚点挂在主规则集上（运行时状态，不是看 pf.conf 文本）。
    public var attached: Bool
    /// 锚点里有 IPv6 封锁规则。
    public var loaded: Bool
    public var permissionDenied: Bool
    public var readable: Bool = true

    public var effective: Bool { enabled && attached && loaded }
}

public struct CommandResult {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
}

public enum Shell {
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 4) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        // isRunning 轮询 / waitUntilExit 每次调用会额外多出 ~90ms（实测 route 9ms → 100ms）；
        // terminationHandler 在子进程退出时立即返回。
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, stdout: "", stderr: error.localizedDescription, timedOut: false)
        }

        let output = PipeOutput()
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            output.setStdout(out.fileHandleForReading.readDataToEndOfFile())
        }
        DispatchQueue.global().async(group: group) {
            output.setStderr(err.fileHandleForReading.readDataToEndOfFile())
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
        }
        _ = group.wait(timeout: .now() + 2)

        let (stdout, stderr) = output.values
        return CommandResult(
            status: process.isRunning ? -1 : process.terminationStatus,
            stdout: String(data: stdout, encoding: .utf8) ?? "",
            stderr: String(data: stderr, encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }
}

/// 读管道的后台线程与调用方之间共享输出；超时返回时后台线程可能仍在写。
private final class PipeOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func setStdout(_ data: Data) { lock.lock(); stdout = data; lock.unlock() }
    func setStderr(_ data: Data) { lock.lock(); stderr = data; lock.unlock() }

    var values: (Data, Data) {
        lock.lock()
        defer { lock.unlock() }
        return (stdout, stderr)
    }
}

public enum SystemProbe {
    public static func interfaceAddress(name: String) -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr else { continue }
            let family = addr.pointee.sa_family
            guard family == AF_INET || family == AF_INET6 else { continue }
            let ifname = String(cString: current.pointee.ifa_name)
            guard ifname == name else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                     &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            if result == 0 {
                return String(cString: host)
            }
        }
        return nil
    }

    public static func interfaceIPv4(name: String) -> String? {
        try? checkedInterfaceIPv4(name: name)
    }

    public static func checkedInterfaceIPv4(name: String) throws -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            throw ClashError.socket("网卡状态读取失败：\(String(cString: strerror(errno)))")
        }
        defer { freeifaddrs(ifaddr) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr else { continue }
            guard addr.pointee.sa_family == AF_INET else { continue }
            let ifname = String(cString: current.pointee.ifa_name)
            guard ifname == name else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                           &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }

    public static func globalIPv6Addresses() -> [String] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var result: [String] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr, addr.pointee.sa_family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                           &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let value = String(cString: host)
                let lower = value.lowercased()
                if lower.hasPrefix("fe80") || lower == "::1" || lower.hasPrefix("fc") || lower.hasPrefix("fd") {
                    continue
                }
                result.append(value)
            }
        }
        return result
    }

    public static func routeInterface(_ ip: String) -> String? {
        try? checkedRouteInterface(ip)
    }

    public static func checkedRouteInterface(_ ip: String) throws -> String {
        let result = Shell.run("/sbin/route", ["-n", "get", ip], timeout: 2)
        guard !result.timedOut, result.status == 0 else {
            throw ClashError.socket("路由读取\(result.timedOut ? "超时" : "失败：" + result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        for line in result.stdout.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("interface:") {
                return trimmed.replacingOccurrences(of: "interface:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        throw ClashError.decode("路由响应没有接口信息")
    }

    public static func systemProxy() -> SystemProxyInfo {
        // 直接读系统动态配置，避免每轮启动 scutil 并解析文本。
        guard let values = SCDynamicStoreCopyProxies(nil) as? [String: Any] else {
            return SystemProxyInfo(entries: [], pacEnabled: false, readable: false)
        }
        var entries: [SystemProxyEntry] = []
        for kind in ["HTTP", "HTTPS", "SOCKS"] where (values["\(kind)Enable"] as? NSNumber)?.boolValue == true {
            entries.append(SystemProxyEntry(kind: kind,
                                            host: values["\(kind)Proxy"] as? String ?? "",
                                            port: (values["\(kind)Port"] as? NSNumber)?.intValue ?? 0))
        }
        return SystemProxyInfo(entries: entries,
                               pacEnabled: (values["ProxyAutoConfigEnable"] as? NSNumber)?.boolValue == true,
                               readable: true)
    }

    /// true = fake-ip；false = 真实 IP（DNS 泄漏）；nil = 无法判断。
    public static func dnsCanaryFakeIP() -> Bool? {
        // Query the configured resolver directly so mDNSResponder's cache cannot
        // keep a stale real IP after TUN is restored.
        let result = Shell.run("/usr/bin/dig", ["+time=1", "+tries=1", "+short", "example.com"], timeout: 3)
        guard result.status == 0 else { return nil }
        let addresses = result.stdout.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = addresses.first else { return nil }
        return first.hasPrefix("198.18.")
    }

    public static func pfAnchor(_ anchor: String) -> PFCheck {
        func denied(_ r: CommandResult) -> Bool {
            r.status != 0 && (r.stderr.contains("Permission denied") || r.stderr.contains("Operation not permitted"))
        }
        let rules = Shell.run("/sbin/pfctl", ["-s", "rules", "-a", anchor], timeout: 2)
        if denied(rules) {
            return PFCheck(enabled: false, attached: false, loaded: false, permissionDenied: true)
        }
        let loaded = rules.status == 0 && rules.stdout.contains("block drop out quick inet6 all")
        let info = Shell.run("/sbin/pfctl", ["-s", "info"], timeout: 2)
        let enabled = info.status == 0 && info.stdout.contains("Status: Enabled")
        // `-s Anchors` 会列出所有加载过规则的锚点，即使主规则集没有引用它；
        // 只有主规则集里出现 anchor "<name>" 时规则才会被求值。
        let main = Shell.run("/sbin/pfctl", ["-s", "rules"], timeout: 2)
        let attached = main.status == 0 && main.stdout
            .components(separatedBy: .newlines)
            .contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("anchor \"\(anchor)\"") }
        let readable = !rules.timedOut && !info.timedOut && !main.timedOut &&
            rules.status == 0 && info.status == 0 && main.status == 0 &&
            (info.stdout.contains("Status: Enabled") || info.stdout.contains("Status: Disabled"))
        return PFCheck(enabled: enabled, attached: attached, loaded: loaded, permissionDenied: false, readable: readable)
    }

    /// 只在本机连接代理入口，不发送代理请求。拒绝连接与调度/读取超时分开。
    public static func proxyPortListening(_ port: Int) throws -> Bool {
        guard (1...65535).contains(port) else { throw ClashError.decode("代理端口无效") }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClashError.socket("无法检查代理端口") }
        defer { close(fd) }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw ClashError.socket("无法设置端口检查") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected == 0 { return true }
        if errno == ECONNREFUSED { return false }
        guard errno == EINPROGRESS else { throw ClashError.socket(String(cString: strerror(errno))) }
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&descriptor, 1, 100) > 0 else { throw ClashError.timeout }
        var error: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0 else { throw ClashError.socket("端口状态读取失败") }
        if error == ECONNREFUSED { return false }
        guard error == 0 else { throw ClashError.socket(String(cString: strerror(error))) }
        return true
    }

    public static func tailscale() -> TailscaleInfo {
        let path = "/usr/local/bin/tailscale"
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return TailscaleInfo(installed: false, running: false, backendState: "Not installed", exitNode: false, ips: [])
        }
        let result = Shell.run(path, ["status", "--json"], timeout: 3)
        if result.status != 0 {
            return TailscaleInfo(installed: true, running: false, backendState: "Stopped", exitNode: false, ips: [])
        }
        guard let data = result.stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return TailscaleInfo(installed: true, running: false, backendState: "Unknown", exitNode: false, ips: [])
        }
        let state = object["BackendState"] as? String ?? "Unknown"
        let running = state == "Running"
        let exit = object["ExitNodeStatus"] != nil && !(object["ExitNodeStatus"] is NSNull)
        let ips = object["TailscaleIPs"] as? [String] ?? []
        return TailscaleInfo(installed: true, running: running, backendState: state, exitNode: exit, ips: ips)
    }

    /// 经 Clash 混合端口请求 Cloudflare trace，拿到出口 IP 和国家。
    /// static.cloudflareinsights.com 在 Clash 规则里显式指向用户选定的策略组，探测不访问任何 Claude 服务。
    /// 失败重试一次；仍失败返回 nil。
    public static func egressProbe(proxyPort: Int) -> (ip: String, country: String)? {
        guard proxyPort > 0 else { return nil }
        for attempt in 0..<2 {
            let result = Shell.run("/usr/bin/curl", [
                "-sS", "--max-time", "4",
                "--proxy", "http://127.0.0.1:\(proxyPort)",
                "https://\(egressProbeHost)/cdn-cgi/trace",
            ], timeout: 5)
            var ip = ""
            var country = ""
            for line in result.stdout.components(separatedBy: .newlines) {
                if line.hasPrefix("ip=") { ip = String(line.dropFirst(3)) }
                if line.hasPrefix("loc=") { country = String(line.dropFirst(4)) }
            }
            if result.status == 0 && !ip.isEmpty { return (ip, country) }
            if attempt == 0 { Thread.sleep(forTimeInterval: 0.3) }
        }
        return nil
    }

    public static let egressProbeHost = "static.cloudflareinsights.com"

    public static func isProcessRunning(_ name: String) -> Bool {
        let result = Shell.run("/usr/bin/pgrep", ["-x", name], timeout: 1)
        return result.status == 0
    }
}
