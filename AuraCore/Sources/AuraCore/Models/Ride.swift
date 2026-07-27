import Foundation

public struct Ride: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case navigate, freeRide }
    public var id: UUID
    public var kind: Kind
    public var startedAt: Date
    public var endedAt: Date?
    /// The ride's track, split at every pause. Points in different segments were never
    /// adjacent — anything that draws a line or measures a delta between two points must
    /// stay inside one segment (spec D1/D4). A ride with no points has ZERO segments.
    public var segments: [RideSegment]
    public var stats: RideStats?
    /// Human-readable destination (e.g. "The Church Brew Works") for a navigate ride,
    /// denormalized so History can show it without re-resolving the Place. nil for free rides.
    public var destinationName: String?
    public var routeId: UUID?
    public var destinationPlaceId: UUID?

    public init(id: UUID = UUID(), kind: Kind, startedAt: Date, endedAt: Date?,
                segments: [RideSegment], stats: RideStats?, destinationName: String? = nil,
                routeId: UUID?, destinationPlaceId: UUID?) {
        self.id = id; self.kind = kind; self.startedAt = startedAt; self.endedAt = endedAt
        self.segments = segments; self.stats = stats; self.destinationName = destinationName
        self.routeId = routeId; self.destinationPlaceId = destinationPlaceId
    }

    /// Builds a single-segment ride from a flat track. Retained deliberately: making a ride
    /// out of points you already know are contiguous is safe, whereas *reading* a ride back
    /// as a flat track is the thing that silently draws across a pause. Hence there is no
    /// matching `track` accessor — use `segments`, or `flattenedPoints` and say so.
    ///
    /// An empty track yields ZERO segments, not one empty segment. That keeps "no points"
    /// single-valued: `RideRecorder.end` drops its trailing empty segment, so a fix-less ride
    /// and its persisted round trip agree, and `Ride`'s `Equatable` survives a save/load.
    public init(id: UUID = UUID(), kind: Kind, startedAt: Date, endedAt: Date?,
                track: [TrackPoint], stats: RideStats?, destinationName: String? = nil,
                routeId: UUID?, destinationPlaceId: UUID?) {
        self.init(id: id, kind: kind, startedAt: startedAt, endedAt: endedAt,
                  segments: track.isEmpty ? [] : [RideSegment(points: track)], stats: stats,
                  destinationName: destinationName, routeId: routeId,
                  destinationPlaceId: destinationPlaceId)
    }

    /// Every point in ride order, pause gaps closed up. Correct for consumers that treat the
    /// track as a bag of samples (elevation series, HealthKit route, encoded blob) and wrong
    /// for anything measuring between consecutive points or stroking a line.
    ///
    /// **O(n), and it allocates a fresh array on every access** — up to ~10,800 points on a
    /// three-hour ride. Bind it to a `let` before use, and never read it inside a SwiftUI
    /// `body` (the live HUD re-evaluates at 30 fps under `TimelineView`).
    public var flattenedPoints: [TrackPoint] { segments.flatMap(\.points) }
}
