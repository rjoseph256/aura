import Foundation

/// Trim math for the navigate traveled-dim (ROH-221). Pure: the HUD passes the SDK's
/// `fractionTraveled` through `sanitized` then `quantized` before it touches the trim
/// paint property — a non-finite or out-of-range value means "no dim", never a wrong dim.
public enum RouteTrim {
    public static func sanitized(_ raw: Double?) -> Double? {
        guard let raw, raw.isFinite else { return nil }
        return min(max(raw, 0), 1)
    }

    public static func quantized(_ fraction: Double, step: Double = 0.005) -> Double {
        (fraction / step).rounded(.down) * step
    }
}
