import Foundation

// MARK: - Unix HTTP client

public enum ClashError: Error, LocalizedError {
    case socket(String)
    case connect(String)
    case timeout
    case http(String)
    case decode(String)

    public var errorDescription: String? {
        switch self {
        case .socket(let s): return "Clash socket 错误: \(s)"
        case .connect(let s): return "无法连接 Clash: \(s)"
        case .timeout: return "Clash 请求超时"
        case .http(let s): return "Clash HTTP 错误: \(s)"
        case .decode(let s): return "Clash 数据解析失败: \(s)"
        }
    }
}

public struct UnixHTTPResponse {
    public var status: Int
    public var body: Data
}

public final class UnixHTTPClient {
    public let socketPath: String
    public var defaultTimeout: TimeInterval = 4

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func get(_ path: String, timeout: TimeInterval? = nil) throws -> UnixHTTPResponse {
        try request(method: "GET", path: path, body: nil, timeout: timeout ?? defaultTimeout)
    }

    public func put(_ path: String, json: [String: Any], timeout: TimeInterval = 4) throws -> UnixHTTPResponse {
        let data = try JSONSerialization.data(withJSONObject: json, options: [])
        return try request(method: "PUT", path: path, body: data, timeout: timeout)
    }

    public func request(method: String, path: String, body: Data?, timeout: TimeInterval = 4) throws -> UnixHTTPResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClashError.socket("socket() 失败") }
        defer { close(fd) }

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let microseconds = Int(max(0.001, timeout) * 1_000_000)
        var tv = timeval(tv_sec: microseconds / 1_000_000, tv_usec: Int32(microseconds % 1_000_000))
        var noPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < 100 else { throw ClashError.socket("socket 路径过长") }
        withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw ClashError.connect(String(cString: strerror(errno)))
        }

        var request = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nAccept: application/json\r\n"
        if let body {
            request += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        }
        request += "\r\n"
        var payload = Data(request.utf8)
        if let body { payload.append(body) }

        try sendAll(fd: fd, data: payload)

        var response = Data()
        var bodyOffset: Int?
        var contentLength: Int?
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            // A trickling or stalled endpoint cannot extend the total request deadline.
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw ClashError.timeout }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(max(1, remaining * 1000)))
            if ready == 0 { throw ClashError.timeout }
            if ready < 0 {
                if errno == EINTR { continue }
                throw ClashError.socket(String(cString: strerror(errno)))
            }
            let n = recv(fd, &buffer, buffer.count, 0)
            if n > 0 {
                response.append(buffer, count: n)
                guard response.count <= 32 * 1024 * 1024 else { throw ClashError.http("响应过大") }
                if bodyOffset == nil, let range = response.range(of: Data("\r\n\r\n".utf8)),
                   let header = String(data: response[..<range.lowerBound], encoding: .utf8) {
                    bodyOffset = range.upperBound
                    let lines = header.components(separatedBy: "\r\n").map { $0.lowercased() }
                    if !lines.contains(where: { $0.hasPrefix("transfer-encoding:") && $0.contains("chunked") }),
                       let line = lines.first(where: { $0.hasPrefix("content-length:") }) {
                        contentLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
                    }
                }
                // 收齐响应即返回，不因服务端在高负载下延迟关闭 socket 而误报超时。
                if let bodyOffset, let contentLength, contentLength >= 0,
                   response.count >= bodyOffset + contentLength { break }
            } else if n == 0 {
                break
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK { throw ClashError.timeout }
                if errno == EINTR { continue }
                throw ClashError.socket(String(cString: strerror(errno)))
            }
        }

        return try parse(response)
    }

    private func sendAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = send(fd, base.advanced(by: sent), data.count - sent, 0)
                if n <= 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK { throw ClashError.timeout }
                    throw ClashError.socket(String(cString: strerror(errno)))
                }
                sent += n
            }
        }
    }

    private func parse(_ data: Data) throws -> UnixHTTPResponse {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            throw ClashError.http("缺少 HTTP 头")
        }
        let headerData = data[..<headerRange.lowerBound]
        let bodyData = data[headerRange.upperBound...]
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw ClashError.http("HTTP 头不是 UTF-8")
        }
        let lines = headerString.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw ClashError.http("缺少状态行") }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else {
            throw ClashError.http("状态行无效")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let idx = line.firstIndex(of: ":") {
                let key = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        var body = Data(bodyData)
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = try decodeChunked(body)
        } else if let lengthString = headers["content-length"], let length = Int(lengthString) {
            guard length >= 0, body.count >= length else { throw ClashError.http("响应未完整接收") }
            if body.count > length { body = body.prefix(length) }
        }
        guard (200..<300).contains(status) else {
            let text = String(data: body, encoding: .utf8) ?? ""
            throw ClashError.http("HTTP \(status) \(text.prefix(200))")
        }
        return UnixHTTPResponse(status: status, body: body)
    }

    private func decodeChunked(_ data: Data) throws -> Data {
        var output = Data()
        var index = data.startIndex
        while index < data.endIndex {
            guard let lineEnd = data[index...].range(of: Data("\r\n".utf8)) else { throw ClashError.http("分块响应不完整") }
            let line = String(data: data[index..<lineEnd.lowerBound], encoding: .utf8)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let sizeString = line.split(separator: ";").first.map(String.init) ?? "0"
            guard let size = Int(sizeString, radix: 16), size >= 0 else { throw ClashError.http("分块长度无效") }
            index = lineEnd.upperBound
            if size == 0 {
                guard data[index...].starts(with: Data("\r\n".utf8)) else { throw ClashError.http("分块响应未结束") }
                return output
            }
            guard let end = data.index(index, offsetBy: size, limitedBy: data.endIndex) else { throw ClashError.http("分块响应未完整接收") }
            output.append(data[index..<end])
            index = end
            guard data[index...].starts(with: Data("\r\n".utf8)) else { throw ClashError.http("分块结束标记缺失") }
            index = data.index(index, offsetBy: 2)
        }
        throw ClashError.http("分块响应未结束")
    }
}

// MARK: - Models

public struct ClashConfig {
    public var mode: String
    public var allowLan: Bool
    public var bindAddress: String
    public var ipv6: Bool
    public var mixedPort: Int
    public var httpPort: Int
    public var socksPort: Int
    public var tunEnabled: Bool
    public var tunDevice: String
    public var autoRoute: Bool
    public var tunInet4: [String]
    public var dnsHijack: [String]
    public var ipv6Address: [String]
    public var sniffing: Bool
    public var snifferEnabled: Bool
    public var findProcessMode: String
}

public struct ProxyInfo {
    public var name: String
    public var type: String
    public var now: String?
    public var all: [String]
    public var delay: Int
    public var dialerProxy: String?
    public var provider: String?

    public var isGroup: Bool {
        ["Selector", "URLTest", "Fallback", "LoadBalance", "Relay"].contains(type)
    }

    /// 流量不经任何代理直接出去。COMPATIBLE 是空策略组的占位，行为等同 DIRECT。
    public var isDirectLike: Bool {
        type == "Direct" || type == "Compatible"
    }

    public var isReject: Bool {
        type == "Reject" || type == "RejectDrop"
    }
}

public struct RuleInfo {
    public var type: String
    public var payload: String
    public var proxy: String
}

public struct ConnectionInfo {
    public var id: String
    public var host: String
    public var destinationIP: String
    public var remoteDestination: String
    public var destinationPort: Int
    public var sourceIP: String
    public var sourcePort: Int
    public var network: String
    public var process: String?
    public var chains: [String]
    public var rule: String
    public var rulePayload: String
    public var upload: Int64
    public var download: Int64
    public var start: String
}

// MARK: - Clash client

public final class ClashClient {
    public let socketPath: String
    private let http: UnixHTTPClient

    public init(socketPath: String? = nil, timeout: TimeInterval = 4) throws {
        let path = socketPath ?? ClashClient.locateSocket()
        guard let path else { throw ClashError.connect("找不到 Clash 控制 socket") }
        self.socketPath = path
        self.http = UnixHTTPClient(socketPath: path)
        self.http.defaultTimeout = timeout
    }

    public static func locateSocket() -> String? {
        if let env = ProcessInfo.processInfo.environment["CLAUDE_GUARD_CLASH_SOCKET"], !env.isEmpty {
            return env
        }
        let uid = getuid()
        let candidates = [
            "/var/run/clash-verge-service/users/\(uid)/verge-mihomo.sock",
            "/tmp/verge-mihomo.sock",
            "\(NSHomeDirectory())/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/verge-mihomo.sock",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    public func version() throws -> String {
        let data = try http.get("/version").body
        let object = try jsonObject(data)
        return object["version"] as? String ?? "unknown"
    }

    public func configs() throws -> ClashConfig {
        let object = try jsonObject(try http.get("/configs").body)
        guard let mode = object["mode"] as? String, ["rule", "global", "direct"].contains(mode.lowercased()),
              let tun = object["tun"] as? [String: Any], let enabled = tun["enable"] as? Bool,
              !enabled || (tun["auto-route"] is Bool && tun["device"] is String) else {
            throw ClashError.decode("/configs 缺少有效的 mode 或 TUN 状态")
        }
        return ClashConfig(
            mode: mode,
            allowLan: object["allow-lan"] as? Bool ?? false,
            bindAddress: object["bind-address"] as? String ?? "",
            ipv6: object["ipv6"] as? Bool ?? false,
            mixedPort: object["mixed-port"] as? Int ?? 0,
            httpPort: object["port"] as? Int ?? 0,
            socksPort: object["socks-port"] as? Int ?? 0,
            tunEnabled: enabled,
            tunDevice: tun["device"] as? String ?? "",
            autoRoute: tun["auto-route"] as? Bool ?? false,
            tunInet4: tun["inet4-address"] as? [String] ?? [],
            dnsHijack: tun["dns-hijack"] as? [String] ?? [],
            ipv6Address: tun["inet6-address"] as? [String] ?? [],
            sniffing: object["sniffing"] as? Bool ?? false,
            snifferEnabled: (object["sniffer"] as? [String: Any])?["enable"] as? Bool ?? (object["sniffing"] as? Bool ?? false),
            findProcessMode: object["find-process-mode"] as? String ?? "unknown"
        )
    }

    public func proxies() throws -> [String: ProxyInfo] {
        let object = try jsonObject(try http.get("/proxies").body)
        guard let dict = object["proxies"] as? [String: Any] else { throw ClashError.decode("/proxies 缺少节点列表") }
        var result: [String: ProxyInfo] = [:]
        for (name, value) in dict {
            guard let item = value as? [String: Any], let type = item["type"] as? String, !type.isEmpty else {
                throw ClashError.decode("/proxies 节点状态不完整")
            }
            let history = item["history"] as? [[String: Any]] ?? []
            let lastDelay = history.last?["delay"] as? Int ?? 0
            result[name] = ProxyInfo(
                name: name,
                type: type,
                now: item["now"] as? String,
                all: item["all"] as? [String] ?? [],
                delay: lastDelay,
                dialerProxy: item["dialer-proxy"] as? String,
                provider: item["provider"] as? String
            )
        }
        return result
    }

    public func rules() throws -> [RuleInfo] {
        let object = try jsonObject(try http.get("/rules").body)
        guard let list = object["rules"] as? [[String: Any]],
              list.allSatisfy({ ($0["type"] as? String)?.isEmpty == false && ($0["proxy"] as? String)?.isEmpty == false }) else {
            throw ClashError.decode("/rules 规则列表不完整")
        }
        return list.map {
            RuleInfo(
                type: $0["type"] as? String ?? "",
                payload: $0["payload"] as? String ?? "",
                proxy: $0["proxy"] as? String ?? ""
            )
        }
    }

    private func jsonInt(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    public func connections() throws -> [ConnectionInfo] {
        let object = try jsonObject(try http.get("/connections").body)
        let list = object["connections"] as? [[String: Any]] ?? []
        return list.map { item in
            let metadata = item["metadata"] as? [String: Any] ?? [:]
            return ConnectionInfo(
                id: item["id"] as? String ?? UUID().uuidString,
                host: metadata["host"] as? String ?? "",
                destinationIP: metadata["destinationIP"] as? String ?? "",
                remoteDestination: metadata["remoteDestination"] as? String ?? "",
                destinationPort: jsonInt(metadata["destinationPort"]),
                sourceIP: metadata["sourceIP"] as? String ?? "",
                sourcePort: jsonInt(metadata["sourcePort"]),
                network: metadata["network"] as? String ?? "",
                process: metadata["process"] as? String,
                chains: item["chains"] as? [String] ?? [],
                rule: item["rule"] as? String ?? "",
                rulePayload: item["rulePayload"] as? String ?? "",
                upload: Int64(jsonInt(item["upload"])),
                download: Int64(jsonInt(item["download"])),
                start: item["start"] as? String ?? ""
            )
        }
    }

    public func selectProxy(group: String, name: String) throws {
        let encoded = group.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? group
        _ = try http.put("/proxies/\(encoded)", json: ["name": name])
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ClashError.decode("根节点不是对象")
            }
            return object
        } catch let error as ClashError {
            throw error
        } catch {
            throw ClashError.decode(error.localizedDescription)
        }
    }
}
