import Foundation

/// Peer heading derived on-device from two consecutive fixes — the live wire carries no bearing.
/// Degrees clockwise from north. Returns nil when a fix is missing or the two coincide (no
/// meaningful direction), so the map draws no cone rather than a random one.
public enum PeerBearing {
    public static func heading(from a: Coordinate, to b: Coordinate) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }
    public static func heading(from a: Coordinate?, to b: Coordinate?) -> Double? {
        guard let a, let b, a != b else { return nil }
        return heading(from: a, to: b)
    }

    /// On-screen rotation for a screen-aligned annotation's pointer (ROH-213). A map view
    /// annotation does not rotate with the camera, so a geographic bearing drawn raw is wrong by
    /// exactly the camera's own bearing on any rotated (course-up) map — subtract it. A non-finite
    /// camera frame falls back to the raw bearing rather than poisoning the rotation with NaN.
    public static func screenAngle(bearing: Double?, cameraBearing: Double) -> Double? {
        guard let bearing else { return nil }
        guard cameraBearing.isFinite else { return bearing }
        return (bearing - cameraBearing + 360).truncatingRemainder(dividingBy: 360)
    }
}
