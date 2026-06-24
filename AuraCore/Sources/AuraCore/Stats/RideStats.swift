public struct RideStats: Equatable, Codable, Sendable {
    public var distanceMeters: Double
    public var movingTimeSeconds: Double
    public var averageSpeedMetersPerSecond: Double
    public var maxSpeedMetersPerSecond: Double
    public var elevationGainMeters: Double

    public init(distanceMeters: Double, movingTimeSeconds: Double,
                averageSpeedMetersPerSecond: Double, maxSpeedMetersPerSecond: Double,
                elevationGainMeters: Double) {
        self.distanceMeters = distanceMeters
        self.movingTimeSeconds = movingTimeSeconds
        self.averageSpeedMetersPerSecond = averageSpeedMetersPerSecond
        self.maxSpeedMetersPerSecond = maxSpeedMetersPerSecond
        self.elevationGainMeters = elevationGainMeters
    }

    public static let zero = RideStats(distanceMeters: 0, movingTimeSeconds: 0,
                                       averageSpeedMetersPerSecond: 0,
                                       maxSpeedMetersPerSecond: 0, elevationGainMeters: 0)
}
