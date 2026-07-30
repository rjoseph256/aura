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
    public static let previewStart = "preview.start"
    public static let summaryDistance = "summary.distance"
    public static let historyRow = "history.row"
}

/// Machine-readable HUD probe line rendered (DEBUG + simulated rides only) so the golden
/// ride asserts raw meters/seconds instead of parsing localized display strings.
public enum RideTestProbe {
    public struct Values: Equatable, Sendable {
        public let distanceMeters: Int
        public let elapsed: Int
        public let elevationGainMeters: Int
    }

    public static func line(distanceMeters: Double, elapsed: Double,
                            elevationGainMeters: Double) -> String {
        "d=\(Int(distanceMeters));e=\(Int(elapsed));g=\(Int(elevationGainMeters))"
    }

    public static func parse(_ line: String) -> Values? {
        var d: Int?, e: Int?, g: Int?
        for part in line.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, let value = Int(pair[1]) else { return nil }
            switch pair[0] {
            case "d": d = value
            case "e": e = value
            case "g": g = value
            default: return nil
            }
        }
        guard let d, let e, let g else { return nil }
        return Values(distanceMeters: d, elapsed: e, elevationGainMeters: g)
    }
}
