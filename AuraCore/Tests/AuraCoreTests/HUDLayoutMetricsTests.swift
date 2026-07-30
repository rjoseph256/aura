import Testing
@testable import AuraCore

@Suite("HUD layout metrics")
struct HUDLayoutMetricsTests {
    @Test("The roster cap is the documented lever for an iPhone SE overflow")
    func rosterCapIsPinned() {
        // ROH-101 adds a pause row to a column that already holds a turn card, the roster, the
        // control cluster and the instrument panel. If the SE overflows, this fraction is the
        // agreed lever — pinned so lowering it is a deliberate, reviewed change.
        #expect(HUDLayoutMetrics.groupRosterMaxHeightFraction == 0.4)
    }

    @Test("The panel height is pinned at the height the panel actually draws")
    func panelHeightIsPinned() {
        // Measured from the panel's accessibility frame on an iPhone SE (3rd generation).
        // Dropping below it puts the slot under the content's `minimumScaleFactor` floor, and
        // the panel goes back to bleeding over the pause row above it.
        #expect(HUDLayoutMetrics.instrumentPanelHeight == 219)
    }

    @Test("The cap leaves room for the rest of the cockpit column")
    func capLeavesRoomForTheColumn() {
        // The roster shares its row with the control cluster, so on the shortest HUD Aura
        // supports — an iPhone SE (3rd generation), 667 pt less its 20 pt status-bar inset —
        // the column is at most the roster cap plus the pause row, the two 8 pt gaps and the
        // panel. That has to leave the turn card somewhere to draw.
        let shortestHUD = 647.0
        let pauseRow = 56.0        // HUDControlMetrics.ride.resolvedHitTarget
        let gaps = 16.0            // two AuraTheme.Spacing.sm gaps
        let column = shortestHUD * HUDLayoutMetrics.groupRosterMaxHeightFraction
            + pauseRow + gaps + HUDLayoutMetrics.instrumentPanelHeight
        #expect(column < shortestHUD)
    }

    @Test("The pre-layout fallback height is positive and finite")
    func fallbackIsSane() {
        #expect(HUDLayoutMetrics.groupRosterFallbackMaxHeight > 0)
        #expect(HUDLayoutMetrics.groupRosterFallbackMaxHeight.isFinite)
    }
}
