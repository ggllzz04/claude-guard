import Foundation
import Testing
@testable import GuardKit

@Suite struct ProxyGroupTests {
    private let custom = "工作代理 🌐"

    private func proxy(_ name: String, type: String, now: String? = nil) -> ProxyInfo {
        ProxyInfo(name: name, type: type, now: now, all: now.map { [$0] } ?? [],
                  delay: 0, dialerProxy: nil, provider: nil)
    }

    @Test func legacySettingsRetainDefaultGroupAndApproval() throws {
        let data = Data(#"{"approvedNodeName":"Fixture","approvedFingerprint":"hash","enforce":true}"#.utf8)
        let settings = try JSONDecoder().decode(GuardSettings.self, from: data)
        #expect(settings.proxyGroup == GuardSettings.defaultProxyGroup)
        #expect(settings.approvedNodeName == "Fixture")
        #expect(settings.approvedFingerprint == "hash")
        #expect(settings.enforce)
        let malformed = try JSONDecoder().decode(GuardSettings.self, from: Data(#"{"proxyGroup":42}"#.utf8))
        #expect(malformed.proxyGroup == GuardSettings.defaultProxyGroup)
    }

    @Test func customGroupPersists() throws {
        let settings = GuardSettings(proxyGroup: custom)
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(GuardSettings.self, from: data) == settings)
    }

    @Test func switchingGroupsPausesProtectionAndRequiresNewApproval() throws {
        let old = GuardSettings(approvedNodeName: "Shared leaf", approvedNodeType: "AnyTLS",
                                approvedFingerprint: "hash", enforce: true)
        var proposed = old
        proposed.proxyGroup = custom
        let updated = try proposed.validatedUpdate(replacing: old, selectorGroups: [custom], mode: .root)
        #expect(updated.proxyGroup == custom)
        #expect(!updated.enforce)
        #expect(updated.approvedNodeName.isEmpty)
        #expect(updated.approvedNodeType.isEmpty)
        #expect(updated.approvedFingerprint == nil)
    }

    @Test func staleDraftCannotOverwriteApprovalWhenGroupIsUnchanged() throws {
        let old = GuardSettings(proxyGroup: custom, approvedNodeName: "Approved", approvedNodeType: "AnyTLS",
                                approvedFingerprint: "current-hash", enforce: true)
        let proposed = GuardSettings(proxyGroup: custom, auditMode: .strict, approvedNodeName: "Stale",
                                     approvedFingerprint: "stale-hash", enforce: true)
        let updated = try proposed.validatedUpdate(replacing: old, selectorGroups: nil, mode: .root)
        #expect(updated.approvedNodeName == "Approved")
        #expect(updated.approvedNodeType == "AnyTLS")
        #expect(updated.approvedFingerprint == "current-hash")
        #expect(updated.enforce)
        #expect(updated.auditMode == .strict)
    }

    @Test func invalidTargetsAreRejected() {
        let old = GuardSettings.default
        for name in ["", " \n\t", "Missing", "Auto", "Leaf"] {
            let proposed = GuardSettings(proxyGroup: name)
            #expect(throws: SettingsError.self) {
                try proposed.validatedUpdate(replacing: old, selectorGroups: [custom], mode: .root)
            }
        }
        #expect(throws: SettingsError.self) {
            try GuardSettings(proxyGroup: custom).validatedUpdate(replacing: old, selectorGroups: nil, mode: .root)
        }
    }

    @Test func groupChoicesExcludeAutomaticGroupsAndLeaves() {
        let proxies = [custom: proxy(custom, type: "Selector", now: "Leaf"),
                       "Auto": proxy("Auto", type: "URLTest", now: "Leaf"),
                       "Leaf": proxy("Leaf", type: "AnyTLS")]
        #expect(GuardService.selectorGroups(in: proxies) == [custom])
        #expect(!RuleAuditor.resolveNode(proxies: proxies, group: "Auto").isLeaf)
    }

    @Test func customGroupWorksWithoutDefaultGroup() {
        let proxies = [custom: proxy(custom, type: "Selector", now: "Leaf"),
                       "Leaf": proxy("Leaf", type: "AnyTLS")]
        let node = RuleAuditor.resolveNode(proxies: proxies, group: custom)
        #expect(node.error == nil)
        #expect(node.group == custom && node.leafName == "Leaf" && node.isLeaf)
        let rules = [RuleInfo(type: "DomainSuffix", payload: "anthropic.com", proxy: custom)]
        let audit = RuleAuditor.audit(rules: rules, proxies: proxies, group: custom, domains: ["api.anthropic.com"])
        #expect(audit.first?.status == .ok)
    }

    @Test func oldGroupWithSameLeafIsNotExplicitBinding() {
        let proxies = [custom: proxy(custom, type: "Selector", now: "Leaf"),
                       GuardSettings.defaultProxyGroup: proxy(GuardSettings.defaultProxyGroup, type: "Selector", now: "Leaf"),
                       "Leaf": proxy("Leaf", type: "AnyTLS")]
        let rules = [RuleInfo(type: "Match", payload: "", proxy: GuardSettings.defaultProxyGroup)]
        #expect(RuleAuditor.audit(rules: rules, proxies: proxies, group: custom,
                                 domains: ["api.anthropic.com"]).first?.status == .warning)
    }

    @Test func runtimeAuditRequiresConfiguredGroupAndLeaf() {
        func verdict(_ chains: [String]) -> Verdict {
            ProcessAuditor.classifyDestination(host: "api.anthropic.com", remote: "203.0.113.1",
                                               chains: chains, group: custom, approvedLeaf: "Approved",
                                               mode: .standard, direct: false).verdict
        }
        #expect(verdict(["Approved", custom]) == .ok)
        #expect(verdict(["Approved", GuardSettings.defaultProxyGroup]) == .violation)
        #expect(verdict(["Other", custom]) == .violation)
    }

    @Test func oldDaemonSnapshotsStillDecode() throws {
        let snapshot = Snapshot(settings: GuardSettings(proxyGroup: custom), selectorGroups: [custom])
        let data = try GuardJSON.encoder.encode(snapshot)
        #expect(try GuardJSON.decoder.decode(Snapshot.self, from: data).selectorGroups == [custom])
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "selectorGroups")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try GuardJSON.decoder.decode(Snapshot.self, from: legacy)
        #expect(decoded.selectorGroups == nil)
        #expect(decoded.settings.proxyGroup == custom)
    }
}
