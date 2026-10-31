import Foundation
import CryptoKit

/// 从 Clash Verge 的 profile YAML 中取出某个节点的配置块并做指纹。
/// 只保存哈希，不记录 server/password 等敏感字段。
public enum ProfileFingerprint {
    public static func fingerprint(leafName: String, profilePath: String = GuardPaths.profilePath) -> String? {
        guard let block = proxyBlock(leafName: leafName, profilePath: profilePath) else { return nil }
        let normalized = block
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard !normalized.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func proxyBlock(leafName: String, profilePath: String = GuardPaths.profilePath) -> String? {
        guard let text = try? String(contentsOfFile: profilePath, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: .newlines)
        var inProxies = false
        var collecting = false
        var collected: [String] = []
        var entryIndent = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inProxies {
                if trimmed == "proxies:" { inProxies = true }
                continue
            }
            if !collecting {
                if trimmed.hasPrefix("- name:") {
                    let name = parseName(trimmed)
                    if name == leafName {
                        collecting = true
                        entryIndent = line.prefix(while: { $0 == " " }).count
                        collected = [line]
                    }
                } else if !line.hasPrefix(" ") && !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                    // 离开 proxies 段
                    break
                }
            } else {
                let indent = line.prefix(while: { $0 == " " }).count
                let isNextEntry = trimmed.hasPrefix("- name:") && indent <= entryIndent
                let isNewTopLevel = !line.hasPrefix(" ") && !trimmed.isEmpty && !trimmed.hasPrefix("#")
                if isNextEntry || isNewTopLevel {
                    break
                }
                collected.append(line)
            }
        }
        return collected.isEmpty ? nil : collected.joined(separator: "\n")
    }

    private static func parseName(_ line: String) -> String? {
        guard let range = line.range(of: "name:") else { return nil }
        var value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        } else if value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }
}
