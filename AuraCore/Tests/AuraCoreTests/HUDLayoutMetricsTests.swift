import Testing
@testable import AuraCore

@Suite("HUD layout metrics")
struct HUDLayoutMetricsTests {
    @Test("The roster cap is the documented lever for an iPhone SE overflow")
    func rosterCapIsPinned() {
        // ROH-101 adds a pause row to a column that already holds a turn card, the roster, the
        // control cluster and a quarter-screen panel. If the SE overflows, this fraction is the
        // agreed lever — pinned so lowering it is a deliberate, reviewed change.
        #expect(HUDLayoutMetrics.groupRosterMaxHeightFraction == 0.4)
    }

    @Test("The cap leaves room for the rest of the cockpit column")
    func capLeavesRoomForTheColumn() {
        // Panel 25% + roster cap must not alone exceed the screen.
        #expect(HUDLayoutMetrics.groupRosterMaxHeightFraction + 0.25 < 1.0)
    }

    @Test("The pre-layout fallback height is positive and finite")
    func fallbackIsSane() {
        #expect(HUDLayoutMetrics.groupRosterFallbackMaxHeight > 0)
        #expect(HUDLayoutMetrics.groupRosterFallbackMaxHeight.isFinite)
    }
}
