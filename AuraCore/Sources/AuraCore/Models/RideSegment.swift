import Foundation

/// One continuous stretch of a ride. A pause closes the current segment and a resume opens
/// a new one, so two points in *different* segments were never adjacent in time or space —
/// which is why the ride model carries segments rather than a flat track with a convention
/// every consumer has to remember (spec D1).
///
/// An **interior** empty segment is legal: a pause before the first fix, or
/// pause → resume → pause with no intervening point, both produce one. Nothing that walks a
/// segment may assume `points` is non-empty. A *trailing* empty segment is dropped when the
/// ride ends, so "no points" has exactly one encoding: zero segments.
///
/// ## Wire-format contract — read before changing this type
///
/// From schema V6 onward this struct's synthesized `Codable` shape (`{"points":[…]}`) is
/// persisted as the `segmentsData` blob and mirrored to CloudKit. Once V6 ships, **any new
/// stored property must be `Optional` or have a default**, or every previously written blob
/// fails to decode. That failure is masked at first by D2's fallback to `trackData`, and
/// becomes unrecoverable ride loss once `trackData` is retired.
///
/// The wrapper object is deliberate rather than incidental: `[[TrackPoint]]` would encode
/// smaller, but per-segment metadata (a pause reason, a resume timestamp) has nowhere to go
/// without a second migration. The `{"points":` overhead is ~12 bytes per segment against a
/// ~1.1 MB three-hour track.
public struct RideSegment: Codable, Equatable, Sendable {
    public var points: [TrackPoint]

    public init(points: [TrackPoint]) { self.points = points }
}
