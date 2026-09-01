import Testing
@testable import AuraCore

struct MapOrnamentMetricsTests {
    @Test func belowTopControlMarginClearsTheControlRow() {
        // Composition is the contract: the 8pt control top padding, the 44pt
        // HUDControlMetrics control, and a breathing gap — margins are measured
        // from the MapView's safe area, same as the controls' own padding.
        #expect(MapOrnamentMetrics.belowTopControlMargin
                == MapOrnamentMetrics.topControlPadding
                + HUDControlMetrics.standard.size
                + MapOrnamentMetrics.controlClearance)
        #expect(MapOrnamentMetrics.belowTopControlMargin >= 56)
    }
}
