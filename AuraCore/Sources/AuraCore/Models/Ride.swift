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
    /// Time the rider spent paused, in seconds. Active time — the number the summary leads
    /// with — is `elapsed - pausedSeconds` (spec D5). It lives here rather than on `RideStats`
    /// because it is a property of the session, not of the track: `RideStats` is a pure
    /// function of the points, which is what lets the recorder recompute it wholesale on
    /// every fix.
    ///
    /// `0` is the correct reading for every ride recorded before pause existed. Persisted
    /// from schema V6 on, in its own denormalized column (pinned by
    /// `pausedSecondsSurvivesTheStoreFromV6`).
    public var pausedSeconds: TimeInterval
    /// When the pause-boundary flush last wrote this ride, or nil once the rider ends it.
    /// Non-nil means the row is a checkpoint: either a ride a kill left behind, or one still
    /// being recorded on another device. It is when *recording* stopped, which is not
    /// necessarily when the rider stopped riding — the recording may also be short, if the
    /// rider resumed and was killed later while moving.
    public var checkpointedAt: Date?
    /// Human-readable destination (e.g. "The Church Brew Works") for a navigate ride,
    /// denormalized so History can show it without re-resolving the Place. nil for free rides.
    public var destinationName: String?
    public var routeId: UUID?
    public var destinationPlaceId: UUID?

    public init(id: UUID = UUID(), kind: Kind, startedAt: Date, endedAt: Date?,
                segments: [RideSegment], stats: RideStats?, pausedSeconds: TimeInterval = 0,
                checkpointedAt: Date? = nil,
                destinationName: String? = nil,
                routeId: UUID?, destinationPlaceId: UUID?) {
        self.id = id; self.kind = kind; self.startedAt = startedAt; self.endedAt = endedAt
        self.segments = segments; self.stats = stats; self.pausedSeconds = pausedSeconds
        self.checkpointedAt = checkpointedAt
        self.destinationName = destinationName
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
                track: [TrackPoint], stats: RideStats?, pausedSeconds: TimeInterval = 0,
                checkpointedAt: Date? = nil,
                destinationName: String? = nil,
                routeId: UUID?, destinationPlaceId: UUID?) {
        self.init(id: id, kind: kind, startedAt: startedAt, endedAt: endedAt,
                  segments: track.isEmpty ? [] : [RideSegment(points: track)], stats: stats,
                  pausedSeconds: pausedSeconds, checkpointedAt: checkpointedAt,
                  destinationName: destinationName,
                  routeId: routeId, destinationPlaceId: destinationPlaceId)
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

extension Ride {
    /// The rider never ended this ride: it is a pause checkpoint that a kill, or a ride still
    /// running on another device, left behind.
    ///
    /// The same rule as `RideSummary.isUnfinished`, and deliberately kept beside it: these are
    /// the ride and its projection, so the two model-layer copies sit in adjacent files where a
    /// change to one is visible from the other. (`WidgetSnapshot.LastRide.isUnfinished` is a
    /// third expression and is *not* a copy — see the note there.)
    ///
    /// The `endedAt == nil` clause is not redundant with `checkpointedAt`. It catches rows
    /// written by the PR #90 dev builds, whose `checkpoint(at:)` wrote a nil `endedAt` and no
    /// marker at all.
    public var isUnfinished: Bool { checkpointedAt != nil || endedAt == nil }
}
