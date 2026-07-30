// AuraCore/Sources/AuraKit/Widgets/WidgetSnapshot.swift
import Foundation
import AuraCore

/// The denormalized projection the home / Lock Screen widgets read. The app builds it
/// from `RideStore.summaries()` + settings and writes it into the App Group container;
/// the widget decodes it with no SwiftData. It lives in AuraKit (it reuses
/// `DistanceUnits`, `WeeklyRideStats`, and `RideAggregator`) but imports no
/// SwiftUI/UIKit/WidgetKit, so it builds and tests on the macOS CI host.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    /// Bumped if the stored shape changes; the snapshot store's reader (`WidgetSnapshotStore.read()`) rejects an unknown version, so a new
    /// widget binary ignores a snapshot an old app wrote (and vice versa) until the app
    /// rewrites it.
    public static let currentVersion = 1

    public struct LastRide: Codable, Equatable, Sendable {
        public let id: UUID
        public let kind: Ride.Kind
        public let startedAt: Date
        public let hasStats: Bool
        public let distanceMeters: Double
        public let movingTimeSeconds: Double
        /// Nil on a payload written before ROH-107, and on every finished ride.
        public let checkpointedAt: Date?
        /// `endedAt` and `pausedSeconds` are here for ROH-112's active-with-elapsed pair, added
        /// now because this struct was being touched anyway. Optional so an existing payload
        /// decodes without a version bump.
        public let endedAt: Date?
        /// **Both optionals are load-bearing beyond ROH-112.** `pausedSeconds` being nil is the
        /// only signal that a decoded payload predates these keys, and `isUnfinished` (below)
        /// reads it that way to avoid badging every ride in an old payload. ROH-112 is expected
        /// to be the next thing to touch this pair: making `pausedSeconds` non-optional (a
        /// default of 0, say) compiles cleanly and kills that guard silently.
        public let pausedSeconds: Double?
        public let elevationGainMeters: Double
        public let destinationName: String?
        public let thumbnailCoordinates: [Coordinate]

        public init(id: UUID, kind: Ride.Kind, startedAt: Date, hasStats: Bool,
                    distanceMeters: Double, movingTimeSeconds: Double,
                    checkpointedAt: Date?, endedAt: Date?, pausedSeconds: Double?,
                    elevationGainMeters: Double, destinationName: String?,
                    thumbnailCoordinates: [Coordinate]) {
            self.id = id; self.kind = kind; self.startedAt = startedAt
            self.hasStats = hasStats; self.distanceMeters = distanceMeters
            self.movingTimeSeconds = movingTimeSeconds
            self.checkpointedAt = checkpointedAt
            self.endedAt = endedAt
            self.pausedSeconds = pausedSeconds
            self.elevationGainMeters = elevationGainMeters
            self.destinationName = destinationName
            self.thumbnailCoordinates = thumbnailCoordinates
        }

        init(_ summary: RideSummary) {
            self.init(id: summary.id, kind: summary.kind, startedAt: summary.startedAt,
                      hasStats: summary.hasStats, distanceMeters: summary.distanceMeters,
                      movingTimeSeconds: summary.movingTimeSeconds,
                      checkpointedAt: summary.checkpointedAt, endedAt: summary.endedAt,
                      pausedSeconds: summary.pausedSeconds,
                      elevationGainMeters: summary.elevationGainMeters,
                      destinationName: summary.destinationName,
                      thumbnailCoordinates: summary.thumbnailCoordinates)
        }
    }

    public struct Week: Codable, Equatable, Sendable {
        public let distanceMeters: Double
        public let rideCount: Int
        public let goalMeters: Double
        public let start: Date
        public let end: Date

        public init(distanceMeters: Double, rideCount: Int, goalMeters: Double,
                    start: Date, end: Date) {
            self.distanceMeters = distanceMeters; self.rideCount = rideCount
            self.goalMeters = goalMeters; self.start = start; self.end = end
        }

        // Elevation and moving time are passed as 0; widgets only use distance/count for goal math.
        private var stats: WeeklyRideStats {
            WeeklyRideStats(distanceMeters: distanceMeters, rideCount: rideCount,
                            elevationGainMeters: 0, movingTimeSeconds: 0)
        }
        /// Clamped 0...1 for the gauge / ring arc.
        public var fraction: Double { stats.goalFraction(goalMeters: goalMeters) }
        /// Uncapped whole percent (an over-goal week reads > 100).
        public var percent: Int { stats.goalPercent(goalMeters: goalMeters) }
    }

    public let version: Int
    public let generatedAt: Date
    public let units: DistanceUnits
    public let lastRide: LastRide?
    public let week: Week

    public init(version: Int = WidgetSnapshot.currentVersion, generatedAt: Date,
                units: DistanceUnits, lastRide: LastRide?, week: Week) {
        self.version = version; self.generatedAt = generatedAt
        self.units = units; self.lastRide = lastRide; self.week = week
    }

    /// Builds the snapshot from the cheap summary projection + settings. `now` is injected
    /// (not `Date()`) so the factory is deterministic and testable.
    ///
    /// `activeRideID` carries **no default**, deliberately: the ride the rider is currently on
    /// must never present itself as their last ride, and a defaulted nil lets a new call site
    /// leak it silently. Excluded by id rather than by `isUnfinished`, because a rider can hold
    /// a recovered unfinished ride from earlier the same week that still belongs in the ring.
    public static func make(summaries: [RideSummary], goalMeters: Double,
                            units: DistanceUnits, now: Date, activeRideID: UUID?,
                            calendar: Calendar = .current) -> WidgetSnapshot {
        let visible = summaries.filter { $0.id != activeRideID }
        let weekly = RideAggregator.weekToDate(visible, now: now, calendar: calendar)
        let interval = calendar.dateInterval(of: .weekOfYear, for: now)
            ?? DateInterval(start: now, end: now)
        let last = RideAggregator.mostRecent(visible).map(LastRide.init)
        return WidgetSnapshot(
            generatedAt: now, units: units, lastRide: last,
            week: Week(distanceMeters: weekly.distanceMeters, rideCount: weekly.rideCount,
                       goalMeters: goalMeters, start: interval.start, end: interval.end))
    }

    /// A copy with the week figures zeroed for the new week (goal, interval, and last ride
    /// preserved) — the provider's week-boundary entry.
    public func weekReset() -> WidgetSnapshot {
        WidgetSnapshot(version: version, generatedAt: generatedAt, units: units,
                       lastRide: lastRide,
                       week: Week(distanceMeters: 0, rideCount: 0, goalMeters: week.goalMeters,
                                  start: week.start, end: week.end))
    }

    /// Canned content for the gallery placeholder and previews. Fixed timestamps keep it
    /// deterministic.
    public static let sample = WidgetSnapshot(
        generatedAt: Date(timeIntervalSince1970: 1_750_000_000),
        units: .imperial,
        lastRide: LastRide(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, kind: .freeRide,
                           startedAt: Date(timeIntervalSince1970: 1_749_900_000),
                           hasStats: true, distanceMeters: 20_000, movingTimeSeconds: 3_720,
                           checkpointedAt: nil,
                           endedAt: Date(timeIntervalSince1970: 1_749_903_720),
                           pausedSeconds: 0,
                           elevationGainMeters: 104, destinationName: nil,
                           thumbnailCoordinates: []),
        week: Week(distanceMeters: 20_000, rideCount: 3, goalMeters: 40_000,
                   start: Date(timeIntervalSince1970: 1_749_600_000),
                   end: Date(timeIntervalSince1970: 1_750_204_800)))
}

extension WidgetSnapshot.LastRide {
    /// True when Aura never recorded this ride's end.
    ///
    /// **Deliberately NOT the same expression as `RideSummary.isUnfinished`** (`checkpointedAt
    /// != nil || endedAt == nil`), and it must not be "corrected" into one. This struct is
    /// decoded from a stored payload, and a payload written before ROH-107 is still version 1 —
    /// so `WidgetSnapshotStore.read()` accepts it and all three new keys decode nil. Under the
    /// summary's expression a nil `endedAt` that only means *the writer did not have the field*
    /// would badge every ride in that payload until the app next foregrounds, which for a widget
    /// user can be days.
    ///
    /// `pausedSeconds != nil` is the provenance guard: a writer that knew about `endedAt` also
    /// wrote `pausedSeconds`, so its presence is what makes a nil `endedAt` mean "no end
    /// recorded" rather than "not written". Pinned by
    /// `WidgetSnapshotTests.aPayloadWrittenWithoutTheNewFieldsStillDecodes`, and the agreement
    /// with the summary predicate on real rides by
    /// `theWidgetPredicateAgreesWithTheSummaryPredicate`.
    public var isUnfinished: Bool { checkpointedAt != nil || (endedAt == nil && pausedSeconds != nil) }
}
