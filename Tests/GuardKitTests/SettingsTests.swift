import Foundation
import Testing
@testable import GuardKit

@Suite struct SettingsTests {
    @Test func testFirstInstallOnlyObservesDesktop() {
        let settings = GuardSettings.default
        #expect(!(settings.enforce))
        #expect(settings.manages(.desktop))
        #expect(!(settings.manages(.code)))
    }

    @Test func testLegacySettingsKeepApproval() throws {
        let json = #"{"approvedNodeName":"Fixture","approvedFingerprint":"fixture-hash","enforce":true}"#
        let settings = try JSONDecoder().decode(GuardSettings.self, from: Data(json.utf8))
        #expect(settings.approvedNodeName == "Fixture")
        #expect(settings.approvedFingerprint == "fixture-hash")
        #expect(settings.enforce)
        #expect(!(settings.manageCode))
    }

    @Test func testMalformedFieldsDoNotDiscardValidFields() throws {
        let json = #"{"pollInterval":"invalid","enforce":true,"manageDesktop":false}"#
        let settings = try JSONDecoder().decode(GuardSettings.self, from: Data(json.utf8))
        #expect(settings.pollInterval == GuardSettings.default.pollInterval)
        #expect(settings.enforce)
        #expect(!(settings.manageDesktop))
    }

    @Test func testEmptySettingsUseDefaults() throws {
        #expect(try JSONDecoder().decode(GuardSettings.self, from: Data("{}".utf8)) == .default)
    }

    @Test func testSettingsRoundTrip() throws {
        let settings = GuardSettings(auditMode: .strict, approvedNodeName: "Fixture", enforce: true, manageCode: true)
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(GuardSettings.self, from: data) == settings)
    }
}
