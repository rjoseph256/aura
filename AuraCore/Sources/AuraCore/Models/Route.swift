import Foundation

public struct Route: Identifiable, Codable, Equatable, Sendable {
    public enum Profile: String, Codable, Sendable {
        case mostPaths, fastest, flattest
    }
    public var id: UUID
    public var origin: Coordinate
    public var destination: Coordinate
    public var waypoints: [Coordinate]
    public var geometry: [Coordinate]
    public var profile: Profile
    public var distanceMeters: Double
    public var estimatedDurationSeconds: Double
    public var elevationGainMeters: Double

    public init(id: UUID = UUID(), origin: Coordinate, destination: Coordinate,
                waypoints: [Coordinate], geometry: [Coordinate], profile: Profile,
                distanceMeters: Double, estimatedDurationSeconds: Double, elevationGainMeters: Double) {
        self.id = id; self.origin = origin; self.destination = destination
        self.waypoints = waypoints; self.geometry = geometry; self.profile = profile
        self.distanceMeters = distanceMeters
        self.estimatedDurationSeconds = estimatedDurationSeconds
        self.elevationGainMeters = elevationGainMeters
    }
}
