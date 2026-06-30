import Testing
import Foundation
@testable import AuraCore

struct LiveShareCadenceTests {
    let cadence = LiveShareCadence()
    @Test func foregroundMovingUsesForegroundInterval() {
        #expect(cadence.interval(for: .moving, lifecycle: .foreground) == cadence.foregroundInterval)
    }
    @Test func backgroundMovingUsesBackgroundInterval() {
        #expect(cadence.interval(for: .moving, lifecycle: .background) == cadence.backgroundInterval)
    }
    @Test func stoppedUsesStationaryRegardlessOfLifecycle() {
        #expect(cadence.interval(for: .stopped, lifecycle: .foreground) == cadence.stationaryInterval)
        #expect(cadence.interval(for: .stopped, lifecycle: .background) == cadence.stationaryInterval)
    }
    @Test func defaultsHonorTheDroppedTimeoutInvariant() {
        // droppedTimeout must be comfortably above the background cadence (>= ~4x).
        // Convert Duration -> seconds WITHOUT truncating (.components.seconds is whole
        // seconds only; sub-second cadences would otherwise read as 0).
        let c = cadence.backgroundInterval.components
        let bgSeconds = Double(c.seconds) + Double(c.attoseconds) / 1e18
        #expect(cadence.droppedTimeout >= 4 * bgSeconds)
    }
}
