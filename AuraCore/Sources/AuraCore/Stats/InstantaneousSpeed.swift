import Foundation

/// The per-fix instantaneous speed feeding the live readout: the CLLocation Doppler
/// value when present, otherwise a position-delta from the previous fix so simulated /
/// GPX rides and Doppler-less fixes still animate. Pure; unit-tested on CI.
public enum InstantaneousSpeed {
    public static func between(previous: TrackPoint?, current: TrackPoint) -> Double {
        if let doppler = current.speedMetersPerSecond, doppler >= 0 { return doppler }
        guard let previous else { return 0 }
        let dt = current.timestamp.timeIntervalSince(previous.timestamp)
        guard dt > 0 else { return 0 }
        return Geo.distance(previous.coordinate, current.coordinate) / dt
    }
}
