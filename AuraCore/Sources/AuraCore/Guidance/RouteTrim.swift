import Foundation

/// Trim math for the navigate traveled-dim (ROH-221). Pure: the HUD passes the SDK's
/// `fractionTraveled` through `sanitized` then `quantized` before it touches the trim
/// paint property — a non-finite or out-of-range value means "no dim", never a wrong dim.
public enum RouteTrim {
    public static func sanitized(_ raw: Double?) -> Double? {
        guard let raw, raw.isFinite else { return nil }
        return min(max(raw, 0), 1)
    }

    /// Snaps `fraction` DOWN onto a `step` grid, so the trim repaints when the dim boundary
    /// actually moves rather than on every progress tick.
    ///
    /// This bounds the boundary's lag behind the puck; it does not remove it. `step` is a
    /// fraction of ROUTE LENGTH, not a distance, so the residual lag scales with the route:
    /// at the 0.001 default it is up to ~5 m on a 5 km ride and ~30 m on a 30 km one. (0.005
    /// shipped first and was ~25 m / ~150 m for the same two rides — invisible on the 1.3 km
    /// verification playback, where a step is ~6 m, which is exactly why it measured clean.)
    ///
    /// Known and deliberately left alone: `floor(fraction / step) * step` is binary floating
    /// point, so on some exact grid points the quotient lands a hair under the integer and the
    /// result drops one FULL extra step (0.087 → 0.086), doubling the lag on that tick only.
    /// A continuously-varying `fractionTraveled` lands exactly on a grid point about never, and
    /// the cost when it does is one more step — ~30 m at the top of the range. Cosmetic.
    public static func quantized(_ fraction: Double, step: Double = 0.001) -> Double {
        (fraction / step).rounded(.down) * step
    }
}
