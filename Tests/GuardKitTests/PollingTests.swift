import Testing
@testable import GuardKit

@Suite struct PollingTests {
    @Test func testHealthyReaderHasNoWarning() {
        #expect(ReadFailureTracker().severity(at: 100) == .ok)
    }

    @Test func testRepeatedFailuresNeedFullGracePeriod() {
        var tracker = ReadFailureTracker()
        for time in [100.0, 101, 102] { tracker.failed(at: time) }
        #expect(tracker.severity(at: 114.99) == .warning)
        #expect(tracker.severity(at: 115) == .critical)
    }

    @Test func testSingleOldFailureNeverBecomesCritical() {
        var tracker = ReadFailureTracker()
        tracker.failed(at: 100)
        #expect(tracker.severity(at: 200) == .warning)
    }

    @Test func testRecoveryResetsFailureHistory() {
        var tracker = ReadFailureTracker()
        for time in [100.0, 101, 102] { tracker.failed(at: time) }
        tracker.succeeded()
        #expect(tracker.severity(at: 200) == .ok)
        tracker.failed(at: 200)
        #expect(tracker.severity(at: 300) == .warning)
    }

    @Test func testDebouncerRequiresDistinctObservationsAndResetsOnRecovery() {
        var debouncer = RiskDebouncer()
        #expect(debouncer.severity("route", failed: true, observedAt: 1) == .warning)
        #expect(debouncer.severity("route", failed: true, observedAt: 1) == .warning)
        #expect(debouncer.severity("route", failed: true, observedAt: 2) == .critical)
        #expect(debouncer.severity("route", failed: false, observedAt: 3) == .ok)
        #expect(debouncer.severity("route", failed: true, observedAt: 4) == .warning)
    }
}
