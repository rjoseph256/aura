import Foundation

/// Accessibility identifiers shared between the app views and the XCUITest screen objects
/// (the AuraUITests target links AuraKit), so a rename is a compile-time break in both
/// places instead of a silent CI failure.
public enum RideTestID {
    public static let hudProbe = "ride.hud.probe"
    public static let hudBack = "ride.hud.back"
    public static let hudEnd = "ride.hud.end"
    /// The cockpit pause/resume control. One identifier for both states — it is one control
    /// whose label changes (ROH-101 P7); assert the state on `hudPausedBanner`, not on this.
    public static let hudPause = "ride.hud.pause"
    /// The PAUSED state chip. Present only while paused, so ROH-103 can assert the state
    /// rather than inferring it from the control's label.
    public static let hudPausedBanner = "ride.hud.paused.banner"
    /// The cockpit's hero speed readout and its composed stats column, both on
    /// `InstrumentChassis` and so shared by the Explore and navigate panels. ROH-103 reads
    /// the rendered values rather than only the probe: the probe attributes a failure to the
    /// coordinator, these attribute it to the view. Identifiers rather than label queries —
    /// a raw "Speed" string in a test would survive a rename with no compile break.
    public static let hudSpeed = "ride.hud.speed"
    public static let hudStats = "ride.hud.stats"
    public static let previewStart = "preview.start"
    public static let summaryDistance = "summary.distance"
    /// The summary's moving-time cell. It discriminates a segmented save (≈4 min) from a
    /// flattened one (≈14 min) — ROH-103's most timing-independent assertion, since moving
    /// time comes from the fixture's own stamps rather than wall clock.
    public static let summaryMoving = "summary.moving"
    public static let historyRow = "history.row"
}

/// Machine-readable HUD probe line rendered (DEBUG + simulated rides only) so the golden
/// ride asserts raw meters/seconds instead of parsing localized display strings.
public enum RideTestProbe {
    public struct Values: Equatable, Sendable {
        public let distanceMeters: Int
        public let elapsed: Int
        public let elevationGainMeters: Int
        /// Decimetres per second, not metres: `pause(at:)` writes exactly 0, so the paused
        /// assertion is an equality, and this resolution also shows a partial-decay
        /// regression that metre truncation would round into looking correct.
        public let speedDecimetersPerSecond: Int?
        /// Live `coordinator.segments.count`. A cheap check that `resume()` ran — NOT proof
        /// of the saved shape: `resume(at:)` appends unconditionally, and the saved ride goes
        /// through `normalizedSegments`, which drops a trailing empty. The distance and
        /// moving-time bands are what prove the segmented save.
        public let segmentCount: Int?
    }

    public static func line(distanceMeters: Double, elapsed: Double,
                            elevationGainMeters: Double,
                            speedMetersPerSecond: Double, segmentCount: Int) -> String {
        "d=\(Int(distanceMeters));e=\(Int(elapsed));g=\(Int(elevationGainMeters))"
            + ";s=\(Int(speedMetersPerSecond * 10));n=\(segmentCount)"
    }

    /// `d`, `e` and `g` are required; `s` and `n` are optional so an app binary predating
    /// ROH-103 still parses. An unknown key is still a hard failure — it means the format
    /// changed in a way this parser does not understand.
    public static func parse(_ line: String) -> Values? {
        var d: Int?, e: Int?, g: Int?, s: Int?, n: Int?
        for part in line.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, let value = Int(pair[1]) else { return nil }
            switch pair[0] {
            case "d": d = value
            case "e": e = value
            case "g": g = value
            case "s": s = value
            case "n": n = value
            default: return nil
            }
        }
        guard let d, let e, let g else { return nil }
        return Values(distanceMeters: d, elapsed: e, elevationGainMeters: g,
                      speedDecimetersPerSecond: s, segmentCount: n)
    }
}
