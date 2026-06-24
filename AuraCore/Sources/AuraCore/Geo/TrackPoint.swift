import Foundation

public struct TrackPoint: Equatable, Codable, Sendable {
    public var coordinate: Coordinate
    public var elevation: Double?   // meters above sea level
    public var timestamp: Date

    public init(coordinate: Coordinate, elevation: Double?, timestamp: Date) {
        self.coordinate = coordinate
        self.elevation = elevation
        self.timestamp = timestamp
    }
}
