import Foundation

public struct RuleAuditResult: Identifiable, Codable, Equatable, Sendable {
    public var id: String { domain }
    public var domain: String
    public var type: String
    public var payload: String
    public var proxy: String
    public var status: Severity
    public var note: String
    public var resolvedLeaf: String?
    public var chain: [String]

    public var ok: Bool { status == .ok }

    public init(domain: String, type: String, payload: String, proxy: String,
                status: Severity, note: String, resolvedLeaf: String? = nil,
                chain: [String] = []) {
        self.domain = domain
        self.type = type
        self.payload = payload
        self.proxy = proxy
        self.status = status
        self.note = note
        self.resolvedLeaf = resolvedLeaf
        self.chain = chain
    }
}

public struct NodeResolution: Equatable, Sendable {
    public var group: String
    public var leafName: String
    public var leafType: String
    public var delay: Int
    public var isLeaf: Bool
    public var chain: [String]
    public var dialerProxy: String?
    public var error: String?
}

public enum RuleAuditor {
    public static let groupName = GuardSettings.defaultProxyGroup

    public static func normalizeType(_ raw: String) -> String {
        switch raw.lowercased() {
        case "domain": return "DOMAIN"
        case "domainsuffix": return "DOMAIN-SUFFIX"
        case "domainkeyword": return "DOMAIN-KEYWORD"
        case "domainregex": return "DOMAIN-REGEX"
        case "ipcidr": return "IP-CIDR"
        case "ipcidr6": return "IP-CIDR6"
        case "geoip": return "GEOIP"
        case "geosite": return "GEOSITE"
        case "ruleset": return "RULE-SET"
        case "match", "final": return "MATCH"
        case "process": return "PROCESS"
        case "processpath": return "PROCESS-PATH"
        case "processname": return "PROCESS-NAME"
        case "dstport": return "DST-PORT"
        case "network": return "NETWORK"
        case "srcport": return "SRC-PORT"
        default: return raw.uppercased()
        }
    }

    public static func firstMatch(domain: String, rules: [RuleInfo]) -> (RuleInfo, Int)? {
        let d = domain.lowercased()
        for (index, rule) in rules.enumerated() {
            let type = normalizeType(rule.type)
            let payload = rule.payload
            switch type {
            case "DOMAIN":
                if d == payload.lowercased() { return (rule, index) }
            case "DOMAIN-SUFFIX":
                let p = payload.lowercased()
                if d == p || d.hasSuffix("." + p) { return (rule, index) }
            case "DOMAIN-KEYWORD":
                if d.contains(payload.lowercased()) { return (rule, index) }
            case "MATCH":
                return (rule, index)
            case "GEOSITE", "RULE-SET", "DOMAIN-REGEX":
                // 在 Claude 规则之前出现不可静态展开的规则，无法证明不会截胡。
                return (rule, index)
            case "PROCESS", "PROCESS-PATH", "PROCESS-NAME":
                // 进程规则无法用域名模拟；当前位置之前没有匹配，继续。
                continue
            default:
                continue
            }
        }
        return nil
    }

    /// 沿策略组 now 一路走到具体节点。返回 (leaf, chain)。
    public static func resolveLeaf(_ name: String,
                                   proxies: [String: ProxyInfo],
                                   depth: Int = 0) -> (leaf: String, chain: [String])? {
        guard depth < 8, let info = proxies[name] else { return nil }
        if info.isGroup {
            guard let next = info.now, !next.isEmpty else { return nil }
            guard let sub = resolveLeaf(next, proxies: proxies, depth: depth + 1) else { return nil }
            return (sub.leaf, [name] + sub.chain)
        }
        return (name, [name])
    }

    public static func audit(rules: [RuleInfo],
                             proxies: [String: ProxyInfo],
                             group: String = groupName,
                             approvedLeaf: String? = nil,
                             domains: [String] = ClaudeDomainCatalog.auditDomains) -> [RuleAuditResult] {
        let aiLeaf: String? = {
            if let approvedLeaf, !approvedLeaf.isEmpty { return approvedLeaf }
            return resolveLeaf(group, proxies: proxies)?.leaf
        }()

        // 红色只给“会直连”（可能暴露真实 IP）；走了别的节点、无法证明、被拒绝都只提示。
        return domains.map { domain in
            guard let (rule, index) = firstMatch(domain: domain, rules: rules) else {
                return RuleAuditResult(domain: domain, type: "NONE", payload: "", proxy: "DIRECT",
                                       status: .critical, note: "没有任何规则命中，mihomo 会直连")
            }
            let type = normalizeType(rule.type)
            let proxy = rule.proxy

            if type == "GEOSITE" || type == "RULE-SET" || type == "DOMAIN-REGEX" {
                return RuleAuditResult(domain: domain, type: type, payload: rule.payload, proxy: proxy,
                                       status: .warning,
                                       note: "首匹配 #\(index)：\(type) 无法静态展开，不能证明显式走 AI")
            }
            if proxy == "DIRECT" {
                return RuleAuditResult(domain: domain, type: type, payload: rule.payload, proxy: proxy,
                                       status: .critical, note: "首匹配 #\(index)：直连")
            }
            if proxy.hasPrefix("REJECT") || proxies[proxy]?.isReject == true {
                return RuleAuditResult(domain: domain, type: type, payload: rule.payload, proxy: proxy,
                                       status: .warning, note: "首匹配 #\(index)：被拒绝（不会泄漏，但 Claude 可能连不上）")
            }
            guard let resolved = resolveLeaf(proxy, proxies: proxies) else {
                return RuleAuditResult(domain: domain, type: type, payload: rule.payload, proxy: proxy,
                                       status: .warning, note: "首匹配 #\(index)：目标不是可解析的具体节点")
            }
            if proxies[resolved.leaf]?.isDirectLike == true {
                return RuleAuditResult(domain: domain, type: type, payload: rule.payload, proxy: proxy,
                                       status: .critical,
                                       note: "首匹配 #\(index)：经 \(resolved.chain.joined(separator: " → ")) 最终直连",
                                       resolvedLeaf: resolved.leaf, chain: resolved.chain)
            }

            let sameLeaf = aiLeaf != nil && resolved.leaf == aiLeaf
            let explicit = proxy == group || proxy == aiLeaf
            let status: Severity = sameLeaf && explicit ? .ok : .warning
            let note: String
            if status == .ok {
                note = "首匹配 #\(index)：显式走 AI"
            } else if sameLeaf {
                note = "首匹配 #\(index)：经 \(resolved.chain.joined(separator: " → ")) 到同一出口，但未显式绑定 AI"
            } else {
                note = "首匹配 #\(index)：出口 \(resolved.leaf) 与 AI \(aiLeaf ?? "未知") 不同"
            }
            return RuleAuditResult(domain: domain, type: type, payload: rule.payload, proxy: proxy,
                                   status: status, note: note, resolvedLeaf: resolved.leaf,
                                   chain: resolved.chain)
        }
    }

    public static func resolveNode(proxies: [String: ProxyInfo], group: String = groupName) -> NodeResolution {
        guard let groupInfo = proxies[group] else {
            return NodeResolution(group: group, leafName: "", leafType: "", delay: 0,
                                  isLeaf: false, chain: [], dialerProxy: nil, error: "找不到策略组 \(group)")
        }
        guard groupInfo.type == "Selector" else {
            return NodeResolution(group: group, leafName: "", leafType: "", delay: 0,
                                  isLeaf: false, chain: [group], dialerProxy: nil,
                                  error: "\(group) 不是 Selector，而是 \(groupInfo.type)")
        }
        guard var current = groupInfo.now, !current.isEmpty else {
            return NodeResolution(group: group, leafName: "", leafType: "", delay: 0,
                                  isLeaf: false, chain: [group], dialerProxy: nil,
                                  error: "\(group) 没有选中节点")
        }

        var chain: [String] = [group]
        var visited = Set<String>()
        var guardCount = 0
        while guardCount < 8 {
            guardCount += 1
            if visited.contains(current) {
                return NodeResolution(group: group, leafName: current, leafType: "", delay: 0,
                                      isLeaf: false, chain: chain, dialerProxy: nil,
                                      error: "策略组出现循环嵌套")
            }
            visited.insert(current)
            chain.append(current)
            guard let info = proxies[current] else {
                return NodeResolution(group: group, leafName: current, leafType: "", delay: 0,
                                      isLeaf: false, chain: chain, dialerProxy: nil,
                                      error: "节点 \(current) 不存在")
            }
            if info.isGroup {
                guard let next = info.now, !next.isEmpty else {
                    return NodeResolution(group: group, leafName: current, leafType: info.type, delay: 0,
                                          isLeaf: false, chain: chain, dialerProxy: nil,
                                          error: "嵌套策略组 \(current) 没有选中节点")
                }
                current = next
                continue
            }
            let isLeaf = !info.isGroup
            return NodeResolution(group: group, leafName: current, leafType: info.type,
                                  delay: info.delay, isLeaf: isLeaf, chain: chain,
                                  dialerProxy: info.dialerProxy, error: nil)
        }
        return NodeResolution(group: group, leafName: current, leafType: "", delay: 0,
                              isLeaf: false, chain: chain, dialerProxy: nil,
                              error: "策略组嵌套过深")
    }
}
