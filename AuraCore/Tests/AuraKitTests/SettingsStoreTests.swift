import XCTest
import Observation
@testable import AuraKit

final class SettingsStoreTests: XCTestCase {
    private func freshStore() -> SettingsStore {
        let suite = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return SettingsStore(defaults: defaults)
    }

    func test_defaults_areImperialVoiceOnDarkMap() {
        let s = freshStore()
        XCTAssertEqual(s.units, .imperial)
        XCTAssertTrue(s.voiceEnabled)
        XCTAssertEqual(s.mapStyle, .dark)
    }

    func test_persistsChanges() {
        let s = freshStore()
        s.units = .metric
        s.voiceEnabled = false
        XCTAssertEqual(s.units, .metric)
        XCTAssertFalse(s.voiceEnabled)
    }

    /// Guards the @Observable contract: mutating a setting must fire an observation
    /// change so SwiftUI views reading it re-render. (A computed-property store would
    /// silently fail this.)
    func test_unitsChange_firesObservation() {
        let s = freshStore()
        var fired = false
        withObservationTracking { _ = s.units } onChange: { fired = true }
        s.units = .metric
        XCTAssertTrue(fired)
    }
}
