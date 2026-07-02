import XCTest
import Observation
import os
@testable import AuraKit

@MainActor
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
    func test_saveToHealth_defaultsOffAndPersists() {
        let s = freshStore()
        XCTAssertFalse(s.saveToHealth)
        s.saveToHealth = true
        XCTAssertTrue(s.saveToHealth)
    }

    func test_turnHaptics_defaultsOnAndPersists() {
        let s = freshStore()
        XCTAssertTrue(s.turnHaptics)
        s.turnHaptics = false
        XCTAssertFalse(s.turnHaptics)
    }

    func test_didCompleteOnboarding_defaultsOffAndPersists() {
        let s = freshStore()
        XCTAssertFalse(s.didCompleteOnboarding)
        s.didCompleteOnboarding = true
        XCTAssertTrue(s.didCompleteOnboarding)
    }

    func test_unitsChange_firesObservation() {
        let s = freshStore()
        // Swift 6: the onChange closure is @Sendable, so a captured local `var`
        // cannot be mutated from inside it. A lock-protected flag is genuinely
        // Sendable and records the one-shot change without an unsafe escape hatch.
        let fired = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking { _ = s.units } onChange: { fired.withLock { $0 = true } }
        s.units = .metric
        XCTAssertTrue(fired.withLock { $0 })
    }
}
