import Foundation

/// Turns a ride's segments into the polylines a map should stroke, so no renderer ever has
/// to decide for itself whether two adjacent points belong in the same line. A pause gap is
/// unrepresentable in the output: pieces never span segments.
///
/// `splitAtMeters` is the rider's own progress along the ride (group rides dim what is
/// already ridden), sourced from `recorder.stats.distanceMeters`.
public enum TrackRibbon {
    public struct Piece: Equatable, Sendable {
        public let coordinates: [Coordinate]
        /// True for the already-ridden portion, which the group map dims.
        public let isBehind: Bool
        /// Index into the original `segments` array. Preserved because runs too short to
        /// stroke are dropped, so output position is not input position — and Pass 4 wants
        /// to render the *current* segment differently while paused.
        public let sourceIndex: Int

        public init(coordinates: [Coordinate], isBehind: Bool, sourceIndex: Int) {
            self.coordinates = coordinates
            self.isBehind = isBehind
            self.sourceIndex = sourceIndex
        }
    }

    /// - Parameter splitAtMeters: nil draws every segment as one bright piece. Non-nil splits
    ///   at that cumulative *ridden* distance into behind/ahead pieces.
    /// - Returns: drawable pieces in ride order. Runs of fewer than two coordinates are
    ///   dropped — a single point strokes nothing.
    public static func pieces(segments: [RideSegment], splitAtMeters: Double?) -> [Piece] {
        var result: [Piece] = []
        // The budget is spent segment by segment. It must NOT be resolved by walking the
        // flattened geometry: that walk includes the straight-line chord across each pause,
        // while `splitAtMeters` comes from segment-aware stats and excludes it. Mixing the
        // two measures the split against a longer track than the rider rode, which freezes
        // the ribbon for the length of the chord after every resume.
        var remaining = splitAtMeters ?? 0
        let splitting = splitAtMeters != nil

        for (index, segment) in segments.enumerated() {
            let run = segment.points.map(\.coordinate)
            guard run.count > 1 else { continue }   // strokes nothing, and contributes no length

            guard splitting else {
                result.append(Piece(coordinates: run, isBehind: false, sourceIndex: index))
                continue
            }

            let local = RouteSplit.splitIndex(geometry: run, atMeters: remaining)
            remaining = max(remaining - length(of: run), 0)

            if local <= 1 {
                result.append(Piece(coordinates: run, isBehind: false, sourceIndex: index))
            } else if local >= run.count {
                result.append(Piece(coordinates: run, isBehind: true, sourceIndex: index))
            } else {
                // Overlap by one point so behind and ahead join without a visual gap. The
                // code this replaces used `prefix(split)` beside `suffix(from: split)`, which
                // left the leg between them stroked by neither — a hairline gap in the
                // ribbon. Fixing it is a deliberate change, not a preservation.
                result.append(Piece(coordinates: Array(run.prefix(local)),
                                    isBehind: true, sourceIndex: index))
                result.append(Piece(coordinates: Array(run.suffix(from: local - 1)),
                                    isBehind: false, sourceIndex: index))
            }
        }
        return result
    }

    private static func length(of run: [Coordinate]) -> Double {
        guard run.count > 1 else { return 0 }
        return (1..<run.count).reduce(0.0) { $0 + Geo.distance(run[$1 - 1], run[$1]) }
    }
}
