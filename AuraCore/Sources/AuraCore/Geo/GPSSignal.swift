import Foundation

/// How trustworthy the current GPS fix is, for the HUD indicator.
public enum SignalQuality: Sendable, Equatable {
    case good, weak, lost
}

/// Pure GPS-fix classification and filtering. No CoreLocation import — the service
/// passes in horizontal accuracy (meters) and fix age (seconds).
public enum GPSFix {
    /// At or under this horizontal accuracy (m), the fix is good.
    public static let goodAccuracy: Double = 20
    /// Over `goodAccuracy` and up to this, the fix is weak but still recorded.
    public static let weakAccuracy: Double = 50
    /// A fix older than this (s) is treated as lost regardless of accuracy.
    public static let maxAge: TimeInterval = 5

    /// Quality for the indicator: accuracy plus staleness.
    public static func quality(horizontalAccuracy: Double, age: TimeInterval) -> SignalQuality {
        guard horizontalAccuracy >= 0, age <= maxAge else { return .lost }
        if horizontalAccuracy <= goodAccuracy { return .good }
        if horizontalAccuracy <= weakAccuracy { return .weak }
        return .lost
    }

    /// Whether a fix may enter the recorded track. Accuracy-only (an accurate but
    /// slightly old fix is still worth recording); negative accuracy is an invalid fix.
    public static func isAcceptable(horizontalAccuracy: Double) -> Bool {
        horizontalAccuracy >= 0 && horizontalAccuracy <= weakAccuracy
    }
}
