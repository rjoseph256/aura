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
        /// How this piece should be stroked. `.paused` marks the run the rider is stopped in
        /// (ROH-101): the map itself says recording has stopped, so the paused state does not
        /// depend on the rider looking at the cockpit.
        ///
        /// Deliberately a value on the piece rather than a term in `RideMapView`'s stroke
        /// ternary: that expression lives in the app target, which has no unit test target,
        /// and this is the pass's headline visual (ROH-105 D5).
        public let style: Style

        // `Style` only ever makes sense qualified as `Piece.Style`; hoisting it to
        // `TrackRibbon.Style` would let it be misapplied to something that isn't a piece for
        // no readability gain.
        // swiftlint:disable:next nesting
        public enum Style: Equatable, Sendable {
            /// A closed segment, or any segment of a ride that is recording.
            case recorded
            /// The run the rider paused in. At most one piece per ribbon.
            case paused
        }

        /// Index into the original `segments` array. Preserved because runs too short to
        /// stroke are dropped, so output position is not input position.
        ///
        /// **`RideMapView` keys its Mapbox annotation group on this, so it must stay unique
        /// across the returned array.** Duplicate IDs collide silently in Mapbox: both
        /// annotations receive the same feature id, and tap resolution finds only the first.
        /// ROH-101 renders the paused run differently, and does it with `style` rather than
        /// emitting a second piece, precisely so this stays one piece per segment. A future rule
        /// that does split a segment must introduce a compound key.
        /// `TrackRibbonTests.test_sourceIndicesAreUnique` documents the invariant, and
        /// `test_pausedStylingKeepsSourceIndicesUnique` now covers the paused case its fixture
        /// could not.
        public let sourceIndex: Int

        public init(coordinates: [Coordinate], sourceIndex: Int, style: Style = .recorded) {
            self.coordinates = coordinates
            self.sourceIndex = sourceIndex
            self.style = style
        }
    }

    /// - Parameter isPaused: whether the ride is stopped right now. When true the **last
    ///   drawn** piece is styled `.paused` — the last drawn one, not the last segment, because
    ///   a trailing single-point segment strokes nothing and is dropped.
    /// - Returns: drawable pieces in ride order, one per segment. Runs of fewer than two
    ///   coordinates are dropped — a single point strokes nothing — without shifting the
    ///   `sourceIndex` of the runs after them.
    public static func pieces(segments: [RideSegment], isPaused: Bool = false) -> [Piece] {
        var pieces = segments.enumerated().compactMap { index, segment -> Piece? in
            let run = segment.points.map(\.coordinate)
            guard run.count > 1 else { return nil }   // strokes nothing
            return Piece(coordinates: run, sourceIndex: index)
        }
        if isPaused, let last = pieces.indices.last {
            pieces[last] = Piece(coordinates: pieces[last].coordinates,
                                 sourceIndex: pieces[last].sourceIndex,
                                 style: .paused)
        }
        return pieces
    }
}
