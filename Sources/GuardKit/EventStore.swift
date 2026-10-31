import Foundation

public final class JSONLStore<T: Codable> {
    public let path: String
    private let lock = NSLock()
    private let maxBytes: UInt64 = 10 * 1024 * 1024
    // 守护每 0.5s 调一次 recent()；缓存避免每次重读、重解析整个文件（最大 10MB）。
    private let cacheLimit = 500
    private var cache: [T]?

    public init(path: String) {
        self.path = path
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
    }

    public func append(_ item: T) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? GuardJSON.encoder.encode(item) else { return }
        var line = data
        line.append(0x0a)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            return
        }
        if cache != nil {
            cache!.append(item)
            if cache!.count > cacheLimit { cache!.removeFirst(cache!.count - cacheLimit) }
        }
        rotateIfNeededLocked()
    }

    public func recent(_ limit: Int = 50) -> [T] {
        lock.lock()
        defer { lock.unlock() }
        if cache == nil { cache = loadLocked() }
        return Array(cache!.suffix(limit))
    }

    private func loadLocked() -> [T] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return lines.suffix(cacheLimit).compactMap {
            guard let data = $0.data(using: .utf8) else { return nil }
            return try? GuardJSON.decoder.decode(T.self, from: data)
        }
    }

    private func rotateIfNeededLocked() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64, size > maxBytes else { return }
        let backup = path + ".1"
        try? FileManager.default.removeItem(atPath: backup)
        try? FileManager.default.moveItem(atPath: path, toPath: backup)
    }
}
