import Foundation

/// Time-aware exponential moving average for the live speed readout. Pure and
/// deterministic so it unit-tests on the macOS CI host. `alpha = 1 - exp(-dt / tau)`
/// adapts to irregular GPS sample spacing; the first sample seeds the value directly.
public struct SpeedSmoother {
    private let timeConstant: TimeInterval
    private var smoothed: Double = 0
    private var lastTime: Date?
    private var seeded = false

    public init(timeConstant: TimeInterval = 2.5) {
        self.timeConstant = timeConstant > 0 ? timeConstant : 2.5
    }

    public var value: Double { smoothed }

    /// Feed one instantaneous sample (m/s). Negative samples are ignored (the value
    /// holds). Returns the new smoothed value.
    @discardableResult
    public mutating func add(_ speed: Double, at time: Date) -> Double {
        guard speed >= 0 else { return smoothed }
        defer { lastTime = time }
        guard seeded, let last = lastTime else {
            seeded = true
            smoothed = speed
            return smoothed
        }
        let dt = time.timeIntervalSince(last)
        guard dt > 0 else { smoothed = speed; return smoothed }
        let alpha = 1 - exp(-dt / timeConstant)
        smoothed += alpha * (speed - smoothed)
        return smoothed
    }

    public mutating func reset() {
        smoothed = 0
        lastTime = nil
        seeded = false
    }
}
