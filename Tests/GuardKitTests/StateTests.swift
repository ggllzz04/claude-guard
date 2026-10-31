import Testing
@testable import GuardKit

@Suite struct StateTests {
    private func check(_ severity: Severity) -> GuardCheck {
        GuardCheck(id: "fixture", title: "Fixture", detail: "", severity: severity, icon: "network")
    }

    @Test func testCriticalRiskRemainsVisibleWhenProtectionIsOff() {
        #expect(GuardState.evaluate(checks: [check(.critical)], mode: .root, enforce: false) == .blocked)
    }

    @Test func testWarningRemainsVisibleWhenProtectionIsOff() {
        #expect(GuardState.evaluate(checks: [check(.warning)], mode: .root, enforce: false) == .attention)
    }

    @Test func testHealthyEnforcingDaemonIsProtected() {
        #expect(GuardState.evaluate(checks: [check(.ok)], mode: .root, enforce: true) == .protected)
    }

    @Test func testHealthyObservationIsDisabled() {
        #expect(GuardState.evaluate(checks: [check(.ok)], mode: .root, enforce: false) == .disabled)
    }

    @Test func testPreviewCannotReportProtected() {
        for mode in [DaemonMode.test, .readOnly] {
            #expect(GuardState.evaluate(checks: [check(.ok)], mode: mode, enforce: true) == .attention)
        }
    }

    @Test func testEmptyChecksAreUnknown() {
        #expect(GuardState.evaluate(checks: [], mode: .root, enforce: true) == .unknown)
    }

    @Test func testTrafficViolationOnlyRaisesAttention() {
        let finding = TrafficFinding(id: "fixture", pid: 0, process: "fixture", host: "example.org",
                                     remote: "203.0.113.1", port: 443, chain: "DIRECT", rule: "MATCH",
                                     verdict: .violation, note: "Fixture")
        #expect(GuardState.evaluate(checks: [check(.ok)], findings: [finding], mode: .root, enforce: true) == .attention)
    }
}
