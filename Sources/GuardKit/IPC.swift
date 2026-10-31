import Foundation

public struct IPCRequest: Codable, Sendable {
    public var id: String
    public var command: String
    public var payload: [String: String]?

    public init(id: String = UUID().uuidString, command: String, payload: [String: String]? = nil) {
        self.id = id
        self.command = command
        self.payload = payload
    }
}

public struct IPCResponse: Codable, Sendable {
    public var id: String
    public var ok: Bool
    public var error: String?
    public var snapshot: Snapshot?
    public var events: [GuardEvent]?
    public var findings: [TrafficFinding]?
    public var settings: GuardSettings?

    public init(id: String = UUID().uuidString, ok: Bool = true, error: String? = nil,
                snapshot: Snapshot? = nil, events: [GuardEvent]? = nil,
                findings: [TrafficFinding]? = nil, settings: GuardSettings? = nil) {
        self.id = id
        self.ok = ok
        self.error = error
        self.snapshot = snapshot
        self.events = events
        self.findings = findings
        self.settings = settings
    }
}

public enum UnixSocketAddress {
    public static func make(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                for (index, byte) in bytes.enumerated() where index < 103 {
                    dst[index] = CChar(bitPattern: byte)
                }
                if bytes.count < 104 { dst[bytes.count] = 0 }
            }
        }
        return addr
    }
}

public final class UnixSocketServer {
    private let path: String
    private let handler: (IPCRequest) -> IPCResponse
    private var fd: Int32 = -1
    private var running = false
    private let acceptQueue = DispatchQueue(label: "com.local.claudeguard.ipc.accept")
    private let clientQueue = DispatchQueue(label: "com.local.claudeguard.ipc.client", attributes: .concurrent)

    public init(path: String, handler: @escaping (IPCRequest) -> IPCResponse) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClashError.socket("IPC socket() 失败") }

        var addr = UnixSocketAddress.make(path)
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw ClashError.socket("IPC bind 失败: \(String(cString: strerror(errno)))")
        }
        chmod(path, 0o600)
        if geteuid() == 0 {
            let uid = GuardPaths.consoleUID
            if let pw = getpwuid(uid) {
                chown(path, uid, pw.pointee.pw_gid)
            }
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw ClashError.socket("IPC listen 失败")
        }
        running = true
        acceptQueue.async { [weak self] in self?.acceptLoop() }
    }

    public func stop() {
        running = false
        if fd >= 0 {
            close(fd)
            fd = -1
        }
        unlink(path)
    }

    private func acceptLoop() {
        while running {
            var clientAddr = sockaddr_un()
            var length = socklen_t(MemoryLayout<sockaddr_un>.size)
            let client = withUnsafeMutablePointer(to: &clientAddr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(fd, $0, &length)
                }
            }
            if client < 0 {
                if running { Thread.sleep(forTimeInterval: 0.05) }
                continue
            }
            clientQueue.async { [weak self] in self?.handle(client: client) }
        }
    }

    private func handle(client: Int32) {
        defer { close(client) }
        var uid: uid_t = 0
        var gid: gid_t = 0
        if getpeereid(client, &uid, &gid) == 0 {
            let allowed = uid == 0 || uid == GuardPaths.consoleUID || uid == getuid()
            if !allowed { return }
        } else {
            return
        }

        var tv = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        guard let line = readLine(client), let data = line.data(using: .utf8),
              let request = try? GuardJSON.decoder.decode(IPCRequest.self, from: data) else {
            return
        }
        let response = handler(request)
        guard let output = try? GuardJSON.encoder.encode(response) else { return }
        var payload = output
        payload.append(0x0a)
        try? sendAll(client, payload)
    }

    private func readLine(_ client: Int32) -> String? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 8 * 1024 * 1024 {
            let n = recv(client, &buffer, buffer.count, 0)
            if n <= 0 { break }
            data.append(buffer, count: n)
            if let range = data.range(of: Data([0x0a])) {
                return String(data: data[..<range.lowerBound], encoding: .utf8)
            }
        }
        return data.isEmpty ? nil : String(data: data, encoding: .utf8)
    }

    private func sendAll(_ client: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = send(client, base.advanced(by: sent), data.count - sent, 0)
                if n <= 0 { throw ClashError.socket("IPC send 失败") }
                sent += n
            }
        }
    }
}

public final class GuardClient {
    public let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func request(_ command: String, payload: [String: String]? = nil) throws -> IPCResponse {
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        guard client >= 0 else { throw ClashError.socket("IPC client socket() 失败") }
        defer { close(client) }

        var tv = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = UnixSocketAddress.make(socketPath)
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            throw ClashError.connect("IPC 连接失败: \(String(cString: strerror(errno)))")
        }

        let request = IPCRequest(command: command, payload: payload)
        var data = try GuardJSON.encoder.encode(request)
        data.append(0x0a)
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = send(client, base.advanced(by: sent), data.count - sent, 0)
                if n <= 0 { throw ClashError.socket("IPC 发送失败") }
                sent += n
            }
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(client, &buffer, buffer.count, 0)
            if n <= 0 { break }
            response.append(buffer, count: n)
            if response.contains(0x0a) { break }
        }
        guard let range = response.range(of: Data([0x0a])) else {
            throw ClashError.timeout
        }
        return try GuardJSON.decoder.decode(IPCResponse.self, from: response[..<range.lowerBound])
    }
}
