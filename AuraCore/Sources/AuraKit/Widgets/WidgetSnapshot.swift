// AuraCore/Sources/AuraKit/Widgets/WidgetSnapshot.swift
import Foundation
import AuraCore

/// The denormalized projection the home / Lock Screen widgets read. The app builds it
/// from `RideStore.summaries()` + settings and writes it into the App Group container;
/// the widget decodes it with no SwiftData. It lives in AuraKit (it reuses
/// `DistanceUnits`, `WeeklyRideStats`, and `RideAggregator`) but imports no
/// SwiftUI/UIKit/WidgetKit, so it builds and tests on the macOS CI host.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    /// Bumped if the stored shape changes; a reader rejects an unknown version, so a new
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
        public let elevationGainMeters: Double
        public let destinationName: String?
        public let thumbnailCoordinates: [Coordinate]

        public init(id: UUID, kind: Ride.Kind, startedAt: Date, hasStats: Bool,
                    distanceMeters: Double, movingTimeSeconds: Double,
                    elevationGainMeters: Double, destinationName: String?,
                    thumbnailCoordinates: [Coordinate]) {
            self.id = id; self.kind = kind; self.startedAt = startedAt
            self.hasStats = hasStats; self.distanceMeters = distanceMeters
            self.movingTimeSeconds = movingTimeSeconds
            self.elevationGainMeters = elevationGainMeters
            self.destinationName = destinationName
            self.thumbnailCoordinates = thumbnailCoordinates
        }

        init(_ summary: RideSummary) {
            self.init(id: summary.id, kind: summary.kind, startedAt: summary.startedAt,
                      hasStats: summary.hasStats, distanceMeters: summary.distanceMeters,
                      movingTimeSeconds: summary.movingTimeSeconds,
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
    public static func make(summaries: [RideSummary], goalMeters: Double,
                            units: DistanceUnits, now: Date,
                            calendar: Calendar = .current) -> WidgetSnapshot {
        let weekly = RideAggregator.weekToDate(summaries, now: now, calendar: calendar)
        let interval = calendar.dateInterval(of: .weekOfYear, for: now)
            ?? DateInterval(start: now, end: now)
        let last = RideAggregator.mostRecent(summaries).map(LastRide.init)
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
        lastRide: LastRide(id: UUID(), kind: .freeRide,
                           startedAt: Date(timeIntervalSince1970: 1_749_900_000),
                           hasStats: true, distanceMeters: 20_000, movingTimeSeconds: 3_720,
                           elevationGainMeters: 104, destinationName: nil,
                           thumbnailCoordinates: []),
        week: Week(distanceMeters: 20_000, rideCount: 3, goalMeters: 40_000,
                   start: Date(timeIntervalSince1970: 1_749_600_000),
                   end: Date(timeIntervalSince1970: 1_750_204_800)))
}
