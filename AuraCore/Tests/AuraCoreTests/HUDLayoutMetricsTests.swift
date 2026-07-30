import Testing
@testable import AuraCore

@Suite("HUD layout metrics")
struct HUDLayoutMetricsTests {
    @Test("The roster cap is pinned")
    func rosterCapIsPinned() {
        // ROH-101 adds a pause row to a column that already holds a turn card, the roster, the
        // control cluster and the instrument panel. This fraction bounds what a long crew list
        // can add to that — pinned so changing it is a deliberate, reviewed decision.
        #expect(HUDLayoutMetrics.groupRosterMaxHeightFraction == 0.4)
    }

    @Test("The panel height is pinned at the height the panel actually draws")
    func panelHeightIsPinned() {
        // Measured from the panel's accessibility frame on an iPhone SE (3rd generation).
        // Dropping below it puts the slot under the content's `minimumScaleFactor` floor, and
        // the panel goes back to bleeding over the pause row above it.
        #expect(HUDLayoutMetrics.instrumentPanelHeight == 219)
    }

    @Test("On the shortest supported screen the cap cannot shrink the row it bounds")
    func theCapIsInertOnAnIPhoneSE() {
        // The roster shares an HStack with the control cluster, so that row is
        // `max(roster, cluster)` and the cap only bites once the roster is the taller of the
        // two. On an iPhone SE it is not, which is why the doc comment on
        // `groupRosterMaxHeightFraction` says the cap is no lever there. This pins that claim:
        // it fails if the fraction rises far enough to matter on an SE, or if the cluster
        // shrinks under it — either way the comment would need rewriting.
        //
        // Floor of the navigate cluster, mirroring `ControlCluster`'s stack on `.ride`
        // metrics: a zoom pill (two hit-height halves either side of a 1 pt hairline) with
        // `pad/2` beneath it, over recenter, mute and End. A floor rather than the exact
        // height because the uniform inter-button gap is currently zero — `AuraTheme.Spacing.md`
        // is 12 pt and the padding compensation subtracts the same 12 — and any gap that
        // reappears only makes the cluster taller, which strengthens the claim. AuraTheme
        // itself is app-target, hence the reconstruction from `HUDControlMetrics`.
        let hit = HUDControlMetrics.ride.resolvedHitTarget
        let pad = hit - HUDControlMetrics.ride.size
        let navigateClusterFloor = (2 * hit + 1) + pad / 2 + 3 * hit
        // iPhone SE (3rd generation): 667 pt of screen less its 20 pt status-bar inset.
        let shortestHUD = 647.0
        let cappedRoster = shortestHUD * HUDLayoutMetrics.groupRosterMaxHeightFraction
        #expect(cappedRoster < navigateClusterFloor, """
            the cap now resolves above the cluster on an SE (\(cappedRoster) pt vs \
            \(navigateClusterFloor) pt) — groupRosterMaxHeightFraction's doc comment says it \
            cannot, so one of the two has to change
            """)
    }

    @Test("The fixed cockpit stack still leaves the top of an iPhone SE for the turn card")
    func theFixedStackLeavesTheTopOfTheScreen() {
        // The part of the column no cap can shrink, and so the part that has to give if an SE
        // overflows: the cluster row, the pause row, the panel, and the two 8 pt gaps between
        // them. The turn card is a separate top overlay, not a member of this VStack, so this
        // is not a clipping bound — it is the headroom the card has before it starts drawing
        // over the cluster. Today that comes to 578 pt of the SE's 647, so the card has 69 pt
        // and a solo SE ride is already close; the stack simply must not outgrow the screen.
        let hit = HUDControlMetrics.ride.resolvedHitTarget
        let pad = hit - HUDControlMetrics.ride.size
        let clusterRow = (2 * hit + 1) + pad / 2 + 3 * hit
        let gaps = 16.0            // two AuraTheme.Spacing.sm gaps
        let fixedStack = clusterRow + hit + gaps + HUDLayoutMetrics.instrumentPanelHeight
        let shortestHUD = 647.0
        #expect(fixedStack < shortestHUD,
                "the cockpit takes \(fixedStack) of the SE's \(shortestHUD) pt")
    }

    @Test("The pre-layout fallback height is positive and finite")
    func fallbackIsSane() {
        #expect(HUDLayoutMetrics.groupRosterFallbackMaxHeight > 0)
        #expect(HUDLayoutMetrics.groupRosterFallbackMaxHeight.isFinite)
    }
}
