import Foundation

/// Sizing for the round map-control buttons the app renders as `HUDControlButton`. Kept here
/// as plain values (no SwiftUI) so the invariants can be unit-tested the way `AuraPalette` is.
///
/// `size` is the drawn circle — its visual weight over the map. `hitTarget` is the tappable
/// frame, which may extend past the circle as invisible padding so the target grows without the
/// control getting visually heavier. The two levers are independent on purpose: ROH-75 grows the
/// tap region for a moving rider while keeping the circle light.
public struct HUDControlMetrics: Equatable, Sendable {
    /// Diameter of the visible circle, in points.
    public let size: Double
    /// Requested tappable frame, in points. Use `resolvedHitTarget` when laying out — it never
    /// reports a value smaller than `size`.
    public let hitTarget: Double

    public init(size: Double, hitTarget: Double) {
        self.size = size
        self.hitTarget = hitTarget
    }

    /// The tap region actually used: never smaller than the drawn circle, so no part of the
    /// visible control is un-tappable even if a preset is misconfigured.
    public var resolvedHitTarget: Double { max(hitTarget, size) }

    /// Stationary chrome (Home, route preview, the ride back chevron): sits at Apple's 44 pt
    /// minimum, which is plenty when the rider is stopped and looking at the screen.
    public static let standard = HUDControlMetrics(size: 44, hitTarget: 44)

    /// The live-ride right-side cluster (recenter / mark / mute / end). A one-handed, gloved
    /// rider on a vibrating bar mount with eyes on the road needs a target well above the floor,
    /// so the tap region grows to 56 pt while the drawn circle stays at 44 pt — the same light
    /// weight over the map, just far more forgiving to hit (ROH-75). 56 keeps the cluster short
    /// enough to sit comfortably above the instrument panel even on the smallest supported
    /// screen (iPhone SE, iOS 17), while still clearing the 44 pt minimum by a wide margin.
    public static let ride = HUDControlMetrics(size: 44, hitTarget: 56)
}
