import Foundation

public struct TrackPoint: Equatable, Codable, Sendable {
    public var coordinate: Coordinate
    public var elevation: Double?   // meters above sea level
    public var timestamp: Date
    /// Instantaneous Doppler speed (m/s) from CLLocation.speed when valid; nil for
    /// GPX/simulated points, reconstructed Health-route points, or fixes without one.
    /// Optional so legacy track blobs (encoded before this field) decode with it nil —
    /// no SwiftData schema migration needed.
    public var speedMetersPerSecond: Double?

    public init(coordinate: Coordinate, elevation: Double?, timestamp: Date,
                speedMetersPerSecond: Double? = nil) {
        self.coordinate = coordinate
        self.elevation = elevation
        self.timestamp = timestamp
        self.speedMetersPerSecond = speedMetersPerSecond
    }
}
