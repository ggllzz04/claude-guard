import Testing
@testable import GuardKit

@Suite struct RuleAuditTests {
    @Test func testClaudeSuffixMustMatchDomainBoundary() {
        #expect(ClaudeDomainCatalog.isClaudeOrTelemetry("api.anthropic.com"))
        #expect(!(ClaudeDomainCatalog.isClaudeOrTelemetry("anthropic.com.attacker.test")))
        #expect(!(ClaudeDomainCatalog.isClaudeOrTelemetry("notanthropic.com")))
    }

    @Test func testDomesticSuffixMustMatchDomainBoundary() {
        #expect(ClaudeDomainCatalog.isDomesticDomain("example.cn"))
        #expect(!(ClaudeDomainCatalog.isDomesticDomain("example.cn.attacker.test")))
    }

    @Test func testGitHubAllowlistMustMatchDomainBoundary() {
        #expect(ClaudeDomainCatalog.isExternalService("API.GITHUB.COM."))
        #expect(ClaudeDomainCatalog.isExternalService("raw.githubusercontent.com"))
        #expect(!(ClaudeDomainCatalog.isExternalService("github.com.attacker.test")))
    }

    @Test func testEarlierDirectRuleWins() {
        let rules = [RuleInfo(type: "Domain", payload: "api.anthropic.com", proxy: "DIRECT"),
                     RuleInfo(type: "DomainSuffix", payload: "anthropic.com", proxy: "🤖 AI")]
        let result = RuleAuditor.audit(rules: rules, proxies: [:], domains: ["api.anthropic.com"])
        #expect(result.first?.status == .critical)
    }

    @Test func testUnexpandableRuleCannotBeProvenSafe() {
        let rules = [RuleInfo(type: "RuleSet", payload: "fixture", proxy: "🤖 AI"),
                     RuleInfo(type: "DomainSuffix", payload: "anthropic.com", proxy: "🤖 AI")]
        #expect(RuleAuditor.audit(rules: rules, proxies: [:], domains: ["api.anthropic.com"]).first?.status == .warning)
    }

    @Test func testMissingRuleIsCritical() {
        #expect(RuleAuditor.audit(rules: [], proxies: [:], domains: ["api.anthropic.com"]).first?.status == .critical)
    }
}
