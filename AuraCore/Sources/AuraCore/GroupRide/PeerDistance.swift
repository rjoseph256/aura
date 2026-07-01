import Foundation

/// Signed along-route gap between self and a peer, formatted for the roster. Uses the peer's
/// `progressMeters` (already on the wire) — a subtraction, no map query. nil when the peer has
/// no position yet (`.awaiting`); `.dropped` copy is the row's job, not this helper's.
public enum PeerDistance {
    private static let evenBandMeters = 15.0
    public static func label(selfProgress: Double, peer: RidePeer, isImperial: Bool) -> String? {
        guard let p = peer.progressMeters else { return nil }
        let delta = p - selfProgress
        if abs(delta) < evenBandMeters { return "even" }
        let direction = delta > 0 ? "ahead" : "behind"
        let magnitude = abs(delta)
        if isImperial {
            let miles = magnitude / 1609.34
            if miles >= 0.1 { return String(format: "%.1f mi %@", miles, direction) }
            return "\(Int((magnitude / 0.3048).rounded())) ft \(direction)"
        } else {
            if magnitude >= 1000 { return String(format: "%.1f km %@", magnitude / 1000, direction) }
            return "\(Int(magnitude.rounded())) m \(direction)"
        }
    }
}
