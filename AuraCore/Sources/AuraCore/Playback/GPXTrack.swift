public struct GPXTrack: Equatable, Sendable {
    public var points: [TrackPoint]
    public init(points: [TrackPoint]) { self.points = points }
}
