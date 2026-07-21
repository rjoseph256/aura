import Testing
@testable import AuraCore

/// The pure zoom-stepping arithmetic behind the +/- map controls (ROH-57). A tap reads the
/// live camera zoom and asks this helper for the next level; the view/Mapbox glue is
/// simulator-verified, but the clamp/monotonicity rules are pinned here the way
/// `HUDControlMetrics` pins the button sizing.
struct MapZoomStepTests {
    @Test func inAddsOneStep() {
        #expect(MapZoomStep.stepped(from: 15, .zoomIn) == 15 + MapZoomStep.step)
    }

    @Test func outSubtractsOneStep() {
        #expect(MapZoomStep.stepped(from: 16, .zoomOut) == 16 - MapZoomStep.step)
    }

    @Test func inClampsAtMax() {
        #expect(MapZoomStep.stepped(from: MapZoomStep.maxZoom, .zoomIn) == MapZoomStep.maxZoom)
        // Less than a full step below the ceiling lands exactly on it, never past.
        #expect(MapZoomStep.stepped(from: MapZoomStep.maxZoom - 0.5, .zoomIn) == MapZoomStep.maxZoom)
    }

    @Test func outClampsAtMin() {
        #expect(MapZoomStep.stepped(from: MapZoomStep.minZoom, .zoomOut) == MapZoomStep.minZoom)
        #expect(MapZoomStep.stepped(from: MapZoomStep.minZoom + 0.5, .zoomOut) == MapZoomStep.minZoom)
    }

    @Test func inNeverReversesWhenPinchedPastMax() {
        // A pinch can carry the camera past the button's ceiling. Tapping "+" there must be a
        // no-op, not a yank back down to maxZoom (which would read as "+" zooming OUT).
        let pinched = MapZoomStep.maxZoom + 2
        #expect(MapZoomStep.stepped(from: pinched, .zoomIn) == pinched)
    }

    @Test func outNeverReversesWhenPinchedPastMin() {
        let pinched = MapZoomStep.minZoom - 2
        #expect(MapZoomStep.stepped(from: pinched, .zoomOut) == pinched)
    }

    @Test func outFromBeyondMaxStepsBackTowardRange() {
        // From a pinched-in zoom, "-" steps down by one toward the range (not a jump to max).
        #expect(MapZoomStep.stepped(from: MapZoomStep.maxZoom + 2, .zoomOut) == MapZoomStep.maxZoom + 1)
    }

    @Test func inFromBelowMinStepsBackTowardRange() {
        #expect(MapZoomStep.stepped(from: MapZoomStep.minZoom - 2, .zoomIn) == MapZoomStep.minZoom - 1)
    }

    @Test func rangeInvariantsHold() {
        #expect(MapZoomStep.minZoom < MapZoomStep.maxZoom)
        #expect(MapZoomStep.step > 0)
        // The ride HUD re-follows at followDefault on recenter; it must sit inside the range.
        #expect(MapZoomStep.followDefault > MapZoomStep.minZoom)
        #expect(MapZoomStep.followDefault < MapZoomStep.maxZoom)
    }
}
