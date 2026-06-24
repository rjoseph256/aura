public struct RouteRequest: Equatable, Sendable {
    public var origin: Coordinate
    public var destination: Coordinate
    public var waypoints: [Coordinate]

    public init(origin: Coordinate, destination: Coordinate, waypoints: [Coordinate] = []) {
        self.origin = origin; self.destination = destination; self.waypoints = waypoints
    }
}
