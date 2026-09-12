import Foundation

extension ReplayTimeline {
    /// Total: any fraction, clamped to 0…1. With no drawable segment the sample is the origin
    /// at `.ended`; the entry point never presents such a timeline (`isReplayable`).
    public func sample(at fraction: Double) -> ReplaySample {
        let f = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        guard let first else {
            return ReplaySample(coordinate: Coordinate(latitude: 0, longitude: 0), bearing: nil, elevation: nil,
                                speedMetersPerSecond: nil, distanceMeters: 0, seconds: 0, phase: .ended)
        }
        if f >= 1 || spans.isEmpty {
            if f < 1 {
                return ReplaySample(coordinate: first.coordinate, bearing: nil, elevation: first.elevation,
                                    speedMetersPerSecond: nil, distanceMeters: 0, seconds: 0, phase: .moving)
            }
            let end = last ?? first
            return ReplaySample(coordinate: end.coordinate, bearing: nil, elevation: end.elevation,
                                speedMetersPerSecond: nil, distanceMeters: totalDistanceMeters,
                                seconds: totalSeconds, phase: .ended)
        }
        let span = spans[spanIndex(atFraction: f)]
        let t = min(max((f * playbackDuration - span.playStart) / span.width, 0), 1)
        switch span.content {
        case let .leg(leg):
            let coordinate = Coordinate(
                latitude: leg.start.coordinate.latitude + (leg.end.coordinate.latitude - leg.start.coordinate.latitude) * t,
                longitude: leg.start.coordinate.longitude + (leg.end.coordinate.longitude - leg.start.coordinate.longitude) * t)
            let seconds = span.secondsAtStart + leg.dt * t
            let window = window(segment: leg.segment, at: seconds)
            return ReplaySample(coordinate: coordinate,
                                bearing: window.bearing ?? leg.bearing,
                                elevation: Self.lerp(leg.start.elevation, leg.end.elevation, t),
                                speedMetersPerSecond: window.speed,
                                distanceMeters: span.distanceAtStart + leg.distance * t,
                                seconds: seconds, phase: .moving)
        case let .hold(hold):
            return ReplaySample(coordinate: hold.anchor.coordinate, bearing: nil, elevation: hold.anchor.elevation,
                                speedMetersPerSecond: nil, distanceMeters: span.distanceAtStart,
                                seconds: hold.advancesClock ? span.secondsAtStart + hold.seconds * t : span.secondsAtStart,
                                phase: .hold(hold.kind, seconds: hold.seconds))
        }
    }

    /// Elevation at `sampleCount` uniform playback fractions (spec D6). nil when no point has one.
    public func profile(sampleCount: Int) -> [Double]? {
        guard sampleCount >= 2 else { return nil }
        var raw: [Double?] = []
        raw.reserveCapacity(sampleCount)
        for k in 0..<sampleCount { raw.append(sample(at: Double(k) / Double(sampleCount - 1)).elevation) }
        guard let firstKnown = raw.compactMap({ $0 }).first else { return nil }
        var out: [Double] = []
        out.reserveCapacity(sampleCount)
        var carry = firstKnown
        for value in raw {
            if let value { carry = value }
            out.append(carry)
        }
        return out
    }

    // MARK: - Internals

    private static func lerp(_ a: Double?, _ b: Double?, _ t: Double) -> Double? {
        switch (a, b) {
        case let (a?, b?): return a + (b - a) * t
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }

    /// Last span whose `fractionStart` ≤ `f`. Spans start at 0 and are contiguous.
    private func spanIndex(atFraction f: Double) -> Int {
        var lo = 0, hi = spans.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if spans[mid].fractionStart <= f { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Spec D5.1 + D9: the trailing window `[T − w, T]` within the segment, never reaching back
    /// past the last in-segment hold. Speed is Σ leg distances over the time span; bearing is
    /// the course between the window's endpoints. Both nil with fewer than two points.
    private func window(segment: Int, at seconds: TimeInterval) -> (speed: Double?, bearing: Double?) {
        let index = segmentIndices[segment]
        let j = Self.lastIndex(in: index.times, atOrBefore: seconds)
        let i = max(Self.firstIndex(in: index.times, atOrAfter: seconds - speedWindowSeconds), index.windowFloor[j])
        guard j > i else { return (nil, nil) }
        let span = index.times[j] - index.times[i]
        let speed = span > 0 ? (index.distances[j] - index.distances[i]) / span : nil
        let a = index.coordinates[i], b = index.coordinates[j]
        let bearing = Geo.distance(a, b) >= config.coincidentMeters ? PeerBearing.heading(from: a, to: b) : nil
        return (speed, bearing)
    }

    static func lastIndex(in times: [TimeInterval], atOrBefore t: TimeInterval) -> Int {
        var lo = 0, hi = times.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if times[mid] <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    static func firstIndex(in times: [TimeInterval], atOrAfter t: TimeInterval) -> Int {
        var lo = 0, hi = times.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] >= t { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }

    /// Spec §4.10: 0, every hold edge, every whole km and mi (a mark that falls inside a hold's
    /// folded distance lands on the hold's start), and 1 — sorted, deduplicated, 1 always kept.
    static func events(spans: [Span], holds: [ReplayHold], duration: TimeInterval) -> [Double] {
        var out: [Double] = [0]
        for hold in holds { out.append(hold.range.lowerBound); out.append(hold.range.upperBound) }
        for span in spans {
            let (distance, from): (Double, Double)
            switch span.content {
            case let .leg(leg): (distance, from) = (leg.distance, span.distanceAtStart)
            case let .hold(hold): (distance, from) = (hold.distance, span.distanceAtStart)
            }
            guard distance > 0 else { continue }
            for unit in [1000.0, 1609.344] {
                var k = (from / unit).rounded(.down) + 1
                while k * unit <= from + distance {
                    let within = (k * unit - from) / distance
                    let offset: Double
                    if case .leg = span.content { offset = within * span.width } else { offset = 0 }
                    out.append((span.playStart + offset) / duration)
                    k += 1
                }
            }
        }
        out = out.filter { $0 < 1 - 1e-9 }.sorted()
        var deduped: [Double] = []
        for f in out where deduped.last.map({ f - $0 > 1e-9 }) ?? true { deduped.append(f) }
        deduped.append(1)
        return deduped
    }
}
