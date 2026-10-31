import Foundation

/// Claude / Anthropic 自有域名，以及常见第三方遥测/审计域名。
/// 规则审计与运行时审计共用这份目录。
public enum ClaudeDomainCatalog {
    public static let coreDomains: [String] = [
        "anthropic.com",
        "anthropic.ai",
        "claude.ai",
        "claude.com",
        "claudeusercontent.com",
        "claudemcpcontent.com",
    ]

    public static let telemetryDomains: [String] = [
        "sentry.io",
        "sentry-cdn.com",
        "statsig.com",
        "statsigapi.net",
        "featuregates.org",
        "featureassets.org",
        "segment.io",
        "segment.com",
        "amplitude.com",
        "datadoghq.com",
        "datadoghq.eu",
        "newrelic.com",
        "nr-data.net",
        "bugsnag.com",
        "logrocket.com",
        "lr-ingest.io",
        "fullstory.com",
        "hotjar.com",
        "hotjar.io",
        "posthog.com",
        "mixpanel.com",
        "google-analytics.com",
        "googletagmanager.com",
    ]

    /// 规则审计用的完整列表。
    public static var auditDomains: [String] {
        coreDomains + telemetryDomains
    }

    public static func isClaudeOrTelemetry(_ host: String) -> Bool {
        let h = host.lowercased()
        guard !h.isEmpty else { return false }
        return (coreDomains + telemetryDomains).contains { h == $0 || h.hasSuffix("." + $0) }
    }

    /// 仓库/API/静态资源属于普通外部服务，遵循 Clash 自身分流，不要求走 AI。
    public static func isExternalService(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return ["github.com", "githubusercontent.com", "githubassets.com"].contains {
            h == $0 || h.hasSuffix("." + $0)
        }
    }

    public static func isDomesticDomain(_ host: String) -> Bool {
        let h = host.lowercased()
        if h.isEmpty { return false }
        if h == "localhost" || h.hasSuffix(".local") || h.hasSuffix(".lan") || h.hasSuffix(".home.arpa") {
            return true
        }
        if h.hasSuffix(".cn") { return true }
        return false
    }

    public static func isPrivateAddress(_ ip: String) -> Bool {
        let s = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return false }
        if s == "::1" || s.lowercased().hasPrefix("fe80:") || s.lowercased().hasPrefix("fc") || s.lowercased().hasPrefix("fd") {
            return true
        }
        var addr = in_addr()
        if inet_pton(AF_INET, s, &addr) == 1 {
            let value = UInt32(bigEndian: addr.s_addr)
            let a = (value >> 24) & 0xff
            let b = (value >> 16) & 0xff
            if a == 10 || a == 127 || a == 0 { return true }
            if a == 172 && (16...31).contains(Int(b)) { return true }
            if a == 192 && b == 168 { return true }
            if a == 169 && b == 254 { return true }
            if a == 100 && (64...127).contains(Int(b)) { return true } // Tailscale CGNAT
            if a >= 224 { return true }
        }
        return false
    }
}
