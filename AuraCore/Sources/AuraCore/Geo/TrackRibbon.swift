import Foundation

/// Turns a ride's segments into the polylines a map should stroke, so no renderer ever has
/// to decide for itself whether two adjacent points belong in the same line. A pause gap is
/// unrepresentable in the output: pieces never span segments.
///
/// Two rules are worth knowing before extending this, both learned the expensive way.
///
/// **Progress along a segmented track must be spent per segment.** It must never be resolved
/// by walking the flattened geometry: that walk includes the straight-line chord across each
/// pause, while segment-aware stats exclude it. Mixing the two measures progress against a
/// longer track than the rider rode, which freezes anything keyed to it for the length of the
/// chord after every resume. A behind/ahead ribbon split that made this mistake shipped dead
/// and was removed in ROH-105; the trap outlived the feature.
///
/// **`sourceIndex` is stable only because the recorder appends solely to the last segment**
/// (`RideRecorder.record`, and `resume(at:)` which appends a fresh one). Any future path that
/// backfills an interior segment — checkpoint restore, GPX import, a replay harness — renumbers
/// these indices, which churns Mapbox annotation identity in `RideMapView`.
public enum TrackRibbon {
    public struct Piece: Equatable, Sendable {
        public let coordinates: [Coordinate]
        /// Index into the original `segments` array. Preserved because runs too short to
        /// stroke are dropped, so output position is not input position.
        ///
        /// **`RideMapView` keys its Mapbox annotation group on this, so it must stay unique
        /// across the returned array.** Duplicate IDs collide silently in Mapbox: both
        /// annotations receive the same feature id, and tap resolution finds only the first.
        /// A future rule that emits more than one piece per segment (Pass 4 / ROH-101 renders
        /// the current segment differently while paused) must introduce a compound key rather
        /// than reusing this one. `TrackRibbonTests.test_sourceIndicesAreUnique` documents the
        /// invariant and catches a regression in today's one-piece-per-segment implementation;
        /// its fixture has no pause state, so it would stay green through a ROH-101-style change
        /// and does not guard against that future rule.
        public let sourceIndex: Int

        public init(coordinates: [Coordinate], sourceIndex: Int) {
            self.coordinates = coordinates
            self.sourceIndex = sourceIndex
        }
    }

    /// - Returns: drawable pieces in ride order, one per segment. Runs of fewer than two
    ///   coordinates are dropped — a single point strokes nothing — without shifting the
    ///   `sourceIndex` of the runs after them.
    public static func pieces(segments: [RideSegment]) -> [Piece] {
        segments.enumerated().compactMap { index, segment in
            let run = segment.points.map(\.coordinate)
            guard run.count > 1 else { return nil }   // strokes nothing
            return Piece(coordinates: run, sourceIndex: index)
        }
    }
}
