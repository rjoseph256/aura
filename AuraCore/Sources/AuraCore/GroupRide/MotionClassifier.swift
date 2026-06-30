import Foundation

/// A timestamped speed reading on the publishing device.
public struct SpeedSample: Equatable, Sendable {
    public let speed: Double      // metres/second
    public let at: Date
    public init(speed: Double, at: Date) {
        self.speed = speed
        self.at = at
    }
}

/// Decides a rider's own `MotionState` from their recent speed history, so the raw
/// speed scalar never has to leave the device. `stopped` requires a fully-covered
/// trailing window of sub-threshold samples (hysteresis), avoiding a flip on a single
/// momentary zero at a light.
public struct MotionClassifier: Sendable {
    public let stoppedSpeed: Double          // metres/second
    public let stoppedDuration: TimeInterval // seconds of sustained low speed

    public init(stoppedSpeed: Double = 0.5, stoppedDuration: TimeInterval = 18) {
        self.stoppedSpeed = stoppedSpeed
        self.stoppedDuration = stoppedDuration
    }

    public func classify(_ samples: [SpeedSample], now: Date) -> MotionState {
        let cutoff = now.addingTimeInterval(-stoppedDuration)
        let inWindow = samples.filter { $0.at >= cutoff && $0.at <= now }
        guard let earliest = inWindow.map(\.at).min(),
              now.timeIntervalSince(earliest) >= stoppedDuration,
              inWindow.allSatisfy({ $0.speed < stoppedSpeed })
        else { return .moving }
        return .stopped
    }
}
