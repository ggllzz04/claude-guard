import Testing
@testable import GuardKit

@Suite struct PollingTests {
    @Test func testHealthyReaderHasNoWarning() {
        #expect(ReadFailureTracker().severity(at: 100) == .ok)
    }

    @Test func testPersistentReadFailuresNeverBecomeConfirmedDanger() {
        var tracker = ReadFailureTracker()
        for time in [100.0, 101, 102, 120, 180, 3600] {
            tracker.failed(at: time)
            #expect(tracker.severity(at: time) == .warning)
        }
        #expect(tracker.severity(at: 86400) == .warning)
        #expect(tracker.consecutiveFailures == 6)
        #expect(tracker.failureDuration(at: 3600) == 3500)
    }

    @Test func testSchedulingGapDoesNotInventProxyFailure() {
        var tracker = ReadFailureTracker()
        for time in [100.0, 101, 102] { tracker.failed(at: time) }
        // A worker can be descheduled for minutes while its peers keep running.
        #expect(tracker.severity(at: 10000) == .warning)
    }

    @Test func testRecoveryResetsFailureHistory() {
        var tracker = ReadFailureTracker()
        for time in [100.0, 101, 102] { tracker.failed(at: time) }
        tracker.succeeded()
        #expect(tracker.severity(at: 200) == .ok)
        #expect(tracker.consecutiveFailures == 0)
        #expect(tracker.failureDuration(at: 200) == 0)
        tracker.failed(at: 200)
        #expect(tracker.severity(at: 300) == .warning)
        #expect(tracker.failureDuration(at: 201) == 1)
    }

    @Test func testUnreadableCachedDangerCannotEnforce() {
        let cached = ProbeReading(value: "DIRECT", severity: Severity.warning, detail: "timeout", observedAt: 1)
        #expect(cached.confirmedSeverity(.critical) == .warning)
        #expect(cached.confirmedSeverity(.ok) == .warning)
        let fresh = ProbeReading(value: "DIRECT", severity: Severity.ok, detail: "", observedAt: 2)
        #expect(fresh.confirmedSeverity(.critical) == .critical)
        #expect(fresh.confirmedSeverity(.ok) == .ok)
    }

    @Test func testDebouncerRequiresDistinctObservationsAndResetsOnRecovery() {
        var debouncer = RiskDebouncer()
        #expect(debouncer.severity("route", failed: true, observedAt: 1) == .warning)
        #expect(debouncer.severity("route", failed: true, observedAt: 1) == .warning)
        #expect(debouncer.severity("route", failed: true, observedAt: 2) == .critical)
        #expect(debouncer.severity("route", failed: false, observedAt: 3) == .ok)
        #expect(debouncer.severity("route", failed: true, observedAt: 4) == .warning)
    }

    @Test func testUnreadableObservationBreaksFaultConfirmation() {
        var debouncer = RiskDebouncer()
        #expect(debouncer.severity("route", failed: true, observedAt: 1) == .warning)
        #expect(debouncer.unavailable("route") == .warning)
        #expect(debouncer.severity("route", failed: true, observedAt: 2) == .warning)
        #expect(debouncer.severity("route", failed: true, observedAt: 3) == .critical)
    }
}
