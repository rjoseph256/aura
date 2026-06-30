import Foundation

public enum RideLifecycle: Sendable {
    case foreground
    case background
}

/// The single tunable config for live sharing: publish cadences (per lifecycle and
/// motion), the sender-side stopped thresholds, and the receiver-side dropped timeout.
/// `foregroundInterval` is lowerable to ~1s without code changes. Invariant:
/// `droppedTimeout >= ~4x backgroundInterval` (a slow backgrounded rider must not
/// false-trip dropped).
public struct LiveShareCadence: Sendable {
    public let foregroundInterval: Duration
    public let backgroundInterval: Duration
    public let stationaryInterval: Duration
    public let stoppedSpeed: Double
    public let stoppedDuration: TimeInterval
    public let droppedTimeout: TimeInterval

    public init(foregroundInterval: Duration = .seconds(2),
                backgroundInterval: Duration = .seconds(6),
                stationaryInterval: Duration = .seconds(15),
                stoppedSpeed: Double = 0.5,
                stoppedDuration: TimeInterval = 18,
                droppedTimeout: TimeInterval = 40) {
        self.foregroundInterval = foregroundInterval
        self.backgroundInterval = backgroundInterval
        self.stationaryInterval = stationaryInterval
        self.stoppedSpeed = stoppedSpeed
        self.stoppedDuration = stoppedDuration
        self.droppedTimeout = droppedTimeout
    }

    public func interval(for motionState: MotionState, lifecycle: RideLifecycle) -> Duration {
        if motionState == .stopped { return stationaryInterval }
        switch lifecycle {
        case .foreground: return foregroundInterval
        case .background: return backgroundInterval
        }
    }
}
