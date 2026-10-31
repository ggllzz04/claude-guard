import Testing
@testable import GuardKit

@Suite struct SmokeTests {
    @Test func testDomainCatalog() {
        #expect(ClaudeDomainCatalog.isClaudeOrTelemetry("api.anthropic.com"))
        #expect(ClaudeDomainCatalog.isClaudeOrTelemetry("statsig.anthropic.com"))
        #expect(ClaudeDomainCatalog.isClaudeOrTelemetry("o123.ingest.sentry.io"))
        #expect(ClaudeDomainCatalog.isDomesticDomain("www.example.cn"))
        #expect(ClaudeDomainCatalog.isPrivateAddress("10.0.0.1"))
        #expect(ClaudeDomainCatalog.isPrivateAddress("192.168.0.10"))
        #expect(!(ClaudeDomainCatalog.isPrivateAddress("1.1.1.1")))
    }

    @Test func testRuleMatch() {
        let rules = [
            RuleInfo(type: "DomainSuffix", payload: "anthropic.com", proxy: "🤖 AI"),
            RuleInfo(type: "Match", payload: "", proxy: "Final"),
        ]
        let proxies = [
            "🤖 AI": ProxyInfo(name: "🤖 AI", type: "Selector", now: "Fixture", all: ["Fixture"],
                              delay: 0, dialerProxy: nil, provider: nil),
            "Fixture": ProxyInfo(name: "Fixture", type: "AnyTLS", now: nil, all: [],
                                 delay: 0, dialerProxy: nil, provider: nil),
        ]
        let result = RuleAuditor.audit(rules: rules, proxies: proxies, domains: ["api.anthropic.com"])
        #expect(result.count == 1)
        #expect(result[0].ok)
    }
}
