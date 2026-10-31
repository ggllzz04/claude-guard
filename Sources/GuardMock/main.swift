import Foundation

@main
struct GuardMockMain {
    static func main() {
        if CommandLine.arguments.contains("--ignore-term") { signal(SIGTERM, SIG_IGN) }
        var connectTarget: String?
        var hold = false
        var listenPort: UInt16?

        var args = Array(CommandLine.arguments.dropFirst())
        while let arg = args.first {
            args.removeFirst()
            switch arg {
            case "--connect":
                connectTarget = args.first
                if !args.isEmpty { args.removeFirst() }
            case "--hold":
                hold = true
            case "--listen":
                if let value = args.first, let port = UInt16(value) {
                    listenPort = port
                    args.removeFirst()
                }
            case "--help", "-h":
                print("Usage: guard-mock [--connect host:port] [--hold] [--listen PORT]")
                exit(0)
            default:
                break
            }
        }

        print("guard-mock pid=\(getpid()) path=\(CommandLine.arguments[0])")
        fflush(stdout)

        if let port = listenPort {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bindResult = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bindResult == 0 {
                listen(fd, 8)
                print("listening on 127.0.0.1:\(port)")
                fflush(stdout)
                // --hold 时保留已接受的连接，对端 socket 才会一直是 ESTABLISHED（否则立刻变 CLOSE_WAIT，审计会跳过）。
                var held: [Int32] = []
                while true {
                    let client = accept(fd, nil, nil)
                    if client >= 0 {
                        if hold { held.append(client) } else { close(client) }
                    }
                }
            }
        }

        if let target = connectTarget {
            let parts = target.split(separator: ":")
            if parts.count == 2, let port = UInt16(parts[1]) {
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = port.bigEndian
                addr.sin_addr.s_addr = inet_addr(String(parts[0]))
                let result = withUnsafePointer(to: &addr) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                print("connect \(target) -> \(result == 0 ? "ok" : "failed")")
                fflush(stdout)
                if !hold { close(fd); exit(result == 0 ? 0 : 1) }
                while true { Thread.sleep(forTimeInterval: 1) }
            }
        }

        if hold {
            while true { Thread.sleep(forTimeInterval: 1) }
        }
    }
}
