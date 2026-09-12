import Foundation

/// A finished ride laid out on a playback axis: moving legs at a constant compression of ride
/// time, and holds — pause gaps, stationary runs, lost-signal legs — at a fixed width each
/// (spec D2, D3). Built once; `sample(at:)` (in `ReplayTimeline+Sample.swift`) is a binary
/// search and allocates nothing.
///
/// Time is normalized here: a leg's `dt` is `max(0, next − prev)`, so a backwards or
/// repeated stamp is a zero-width leg that keeps its distance and occupies no time. Nothing
/// downstream guards `dt > 0` again.
public struct ReplayTimeline: Sendable, Equatable {
    public struct Config: Sendable, Equatable {
        public var rate: Double = 120
        public var minPlayback: TimeInterval = 10
        public var maxPlayback: TimeInterval = 45
        public var minHold: TimeInterval = 1.5
        public var maxHold: TimeInterval = 4
        public var maxHoldShare: Double = 0.25
        public var signalGapSeconds: TimeInterval = 30
        public var holdDistanceMeters: Double = 50
        public var stoppedSpeed: Double = 0.5
        public var minStopSeconds: TimeInterval = 45
        public var minPauseSeconds: TimeInterval = 5
        public var speedWindowFloor: TimeInterval = 5
        public var speedWindowPlayback: TimeInterval = 0.1
        public var coincidentMeters: Double = 0.5
        public var minReplayableSeconds: TimeInterval = 60
        public var minReplayableMeters: Double = 200
        public init() {}
    }

    struct Endpoint: Sendable, Equatable {
        var coordinate: Coordinate
        var elevation: Double?
    }

    struct Leg: Sendable, Equatable {
        var segment: Int
        var startIndex: Int
        var start: Endpoint
        var end: Endpoint
        var distance: Double
        var dt: TimeInterval
        var bearing: Double?
    }

    struct Hold: Sendable, Equatable {
        var kind: ReplayHold.Kind
        var seconds: TimeInterval
        var anchor: Endpoint
        /// In-segment holds advance the ride clock across their width; a pause gap does not.
        var advancesClock: Bool
        /// Distance folded into the hold (jitter, or the lost-signal leg). Counted after it.
        var distance: Double
    }

    enum Item: Sendable, Equatable {
        case leg(Leg)
        case hold(Hold)
        /// A zero-width leg: distance only, no time, never a span.
        case skip(distance: Double)
    }

    enum SpanContent: Sendable, Equatable {
        case leg(Leg)
        case hold(Hold)
    }

    struct Span: Sendable, Equatable {
        var content: SpanContent
        var playStart: TimeInterval
        var width: TimeInterval
        /// `playStart / playbackDuration`, stored so the search uses the SAME divided value the
        /// hold ranges are built from. Searching on seconds put a hold's exclusive end back
        /// inside the hold in 94 of 115 sampled gaps (plan review, v1).
        var fractionStart: Double
        var distanceAtStart: Double
        var secondsAtStart: TimeInterval
    }

    /// Per drawable segment: global cumulative seconds and distance at each point, the point
    /// coordinates, and for each point the index the speed/bearing window may not look behind
    /// (the end of the last in-segment hold, spec D5.1).
    struct SegmentIndex: Sendable, Equatable {
        var times: [TimeInterval]
        var distances: [Double]
        var coordinates: [Coordinate]
        var windowFloor: [Int]
    }

    public let config: Config
    public let playbackDuration: TimeInterval
    public let rate: Double
    /// `max(speedWindowFloor, rate × speedWindowPlayback)`: 12 s at 120×, 5 s at 30× (D5.1).
    public let speedWindowSeconds: TimeInterval
    public let totalDistanceMeters: Double
    public let totalSeconds: TimeInterval
    public let isReplayable: Bool
    /// The coordinates of every drawable segment (≥ 2 points), in order. The one definition of
    /// "drawable" the map and the sampler share.
    public let drawableLines: [[Coordinate]]
    public let holds: [ReplayHold]
    public let events: [Double]

    let spans: [Span]
    let segmentIndices: [SegmentIndex]
    let first: Endpoint?
    let last: Endpoint?

    public init(segments: [RideSegment], config: Config = .init()) {
        self.config = config
        let drawable = segments.filter { $0.points.count > 1 }
        var builder = Builder(config: config)
        for (index, segment) in drawable.enumerated() { builder.add(segment, index: index) }
        segmentIndices = builder.segmentIndices
        totalDistanceMeters = builder.cumulativeDistance
        totalSeconds = builder.cumulativeSeconds
        drawableLines = drawable.map { $0.points.map(\.coordinate) }
        first = drawable.first.map { Endpoint(coordinate: $0.points[0].coordinate, elevation: $0.points[0].elevation) }
        last = drawable.last.map { seg in
            let p = seg.points[seg.points.count - 1]
            return Endpoint(coordinate: p.coordinate, elevation: p.elevation)
        }
        let layout = Self.layout(items: builder.items, config: config)
        playbackDuration = layout.duration
        rate = layout.rate
        speedWindowSeconds = max(config.speedWindowFloor, layout.rate * config.speedWindowPlayback)
        spans = layout.spans
        holds = layout.spans.compactMap { span in
            guard case let .hold(hold) = span.content else { return nil }
            return ReplayHold(kind: hold.kind, seconds: hold.seconds,
                              range: span.fractionStart..<((span.playStart + span.width) / layout.duration))
        }
        isReplayable = !drawable.isEmpty
            && layout.movingSpan >= config.minReplayableSeconds
            && totalDistanceMeters >= config.minReplayableMeters
        events = Self.events(spans: spans, holds: holds, duration: layout.duration)
    }

    struct Layout {
        var spans: [Span]
        var duration: TimeInterval
        var rate: Double
        var movingSpan: TimeInterval
    }

    /// D2 + D3: the moving span at constant compression, holds at clamped widths capped as a
    /// share of the moving playback. `duration` is the exact sum, not an accumulation.
    static func layout(items: [Item], config: Config) -> Layout {
        var movingSpan: TimeInterval = 0
        for case let .leg(leg) in items { movingSpan += leg.dt }
        let movingPlayback = min(max(movingSpan / config.rate, config.minPlayback), config.maxPlayback)
        let rate = movingSpan / movingPlayback

        var holdWidths: [TimeInterval] = []
        for case let .hold(hold) in items {
            let raw = rate > 0 ? hold.seconds / rate : config.maxHold
            holdWidths.append(min(max(raw, config.minHold), config.maxHold))
        }
        let holdTotal = holdWidths.reduce(0, +)
        let holdCap = config.maxHoldShare * movingPlayback
        if holdTotal > holdCap, holdTotal > 0 {
            let scale = holdCap / holdTotal
            holdWidths = holdWidths.map { $0 * scale }
        }
        let duration = movingPlayback + holdWidths.reduce(0, +)

        var spans: [Span] = []
        var play: TimeInterval = 0, distance = 0.0, seconds: TimeInterval = 0
        var holdCursor = 0
        for item in items {
            switch item {
            case let .skip(d):
                distance += d
            case let .leg(leg):
                let width = movingSpan > 0 ? leg.dt * movingPlayback / movingSpan : 0
                if width > 0 {
                    spans.append(Span(content: .leg(leg), playStart: play, width: width,
                                      fractionStart: play / duration, distanceAtStart: distance, secondsAtStart: seconds))
                    play += width
                }
                distance += leg.distance
                seconds += leg.dt
            case let .hold(hold):
                let width = holdWidths[holdCursor]
                holdCursor += 1
                spans.append(Span(content: .hold(hold), playStart: play, width: width,
                                  fractionStart: play / duration, distanceAtStart: distance, secondsAtStart: seconds))
                play += width
                distance += hold.distance
                if hold.advancesClock { seconds += hold.seconds }
            }
        }
        return Layout(spans: spans, duration: duration, rate: rate, movingSpan: movingSpan)
    }

    /// Walks segments once, classifying legs (spec D2) and emitting items in ride order.
    struct Builder {
        let config: Config
        var items: [Item] = []
        var segmentIndices: [SegmentIndex] = []
        var cumulativeDistance = 0.0
        var cumulativeSeconds: TimeInterval = 0
        private var previousLast: TrackPoint?
        /// Legs of the stationary run being accumulated; flushed at a moving leg or the end.
        private var run: [Leg] = []
        private var lastBearing: Double?
        /// Point indices in the current segment where an in-segment hold ends.
        private var barriers: [Int] = []

        init(config: Config) { self.config = config }

        mutating func add(_ segment: RideSegment, index: Int) {
            let points = segment.points
            addPauseGap(before: points[0])
            lastBearing = nil
            barriers = []
            var times = [cumulativeSeconds], distances = [cumulativeDistance]
            for i in 1..<points.count {
                let a = points[i - 1], b = points[i]
                let dt = max(0, b.timestamp.timeIntervalSince(a.timestamp))
                let d = Geo.distance(a.coordinate, b.coordinate)
                cumulativeDistance += d
                cumulativeSeconds += dt
                times.append(cumulativeSeconds)
                distances.append(cumulativeDistance)
                if d >= config.coincidentMeters { lastBearing = PeerBearing.heading(from: a.coordinate, to: b.coordinate) }
                let leg = Leg(segment: index, startIndex: i - 1,
                              start: Endpoint(coordinate: a.coordinate, elevation: a.elevation),
                              end: Endpoint(coordinate: b.coordinate, elevation: b.elevation),
                              distance: d, dt: dt, bearing: lastBearing)
                classify(leg, endIndex: i)
            }
            flushRun()
            segmentIndices.append(SegmentIndex(times: times, distances: distances,
                                               coordinates: points.map(\.coordinate),
                                               windowFloor: Self.floors(barriers: barriers, count: points.count)))
            previousLast = points[points.count - 1]
        }

        private mutating func addPauseGap(before first: TrackPoint) {
            guard let prev = previousLast else { return }
            let gap = max(0, first.timestamp.timeIntervalSince(prev.timestamp))
            guard gap >= config.minPauseSeconds else { return }
            items.append(.hold(Hold(kind: .paused, seconds: gap,
                                    anchor: Endpoint(coordinate: prev.coordinate, elevation: prev.elevation),
                                    advancesClock: false, distance: 0)))
        }

        private mutating func classify(_ leg: Leg, endIndex: Int) {
            if leg.dt >= config.signalGapSeconds {
                flushRun()
                let kind: ReplayHold.Kind = leg.distance < config.holdDistanceMeters ? .stopped : .signalLost
                items.append(.hold(Hold(kind: kind, seconds: leg.dt, anchor: leg.start,
                                        advancesClock: true, distance: leg.distance)))
                barriers.append(endIndex)
            } else if leg.dt == 0 {
                classifyZeroWidth(leg)
            } else if leg.distance / leg.dt < config.stoppedSpeed {
                run.append(leg)
            } else {
                flushRun()
                items.append(.leg(leg))
            }
        }

        /// Zero width. A real displacement with no time is not "stopped"; it breaks a run.
        private mutating func classifyZeroWidth(_ leg: Leg) {
            if leg.distance >= config.coincidentMeters {
                flushRun(); items.append(.skip(distance: leg.distance))
            } else if run.isEmpty {
                items.append(.skip(distance: leg.distance))
            } else {
                run.append(leg)
            }
        }

        private mutating func flushRun() {
            guard let head = run.first, let tail = run.last else { return }
            let seconds = run.reduce(0) { $0 + $1.dt }
            if seconds >= config.minStopSeconds {
                items.append(.hold(Hold(kind: .stopped, seconds: seconds, anchor: head.start,
                                        advancesClock: true, distance: run.reduce(0) { $0 + $1.distance })))
                barriers.append(tail.startIndex + 1)
            } else {
                for leg in run { items.append(leg.dt > 0 ? .leg(leg) : .skip(distance: leg.distance)) }
            }
            run.removeAll(keepingCapacity: true)
        }

        /// `floors[j]` = the greatest barrier ≤ j, or 0.
        static func floors(barriers: [Int], count: Int) -> [Int] {
            var out = [Int](repeating: 0, count: count)
            var current = 0
            var next = 0
            for j in 0..<count {
                while next < barriers.count, barriers[next] <= j { current = barriers[next]; next += 1 }
                out[j] = current
            }
            return out
        }
    }
}
