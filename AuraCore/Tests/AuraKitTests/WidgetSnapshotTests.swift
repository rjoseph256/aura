// AuraCore/Tests/AuraKitTests/WidgetSnapshotTests.swift
import Testing
import Foundation
import AuraCore
@testable import AuraKit

@Suite struct WidgetSnapshotTests {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2 // Monday
        return c
    }
    private func date(_ day: Int, hour: Int = 12) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 6, day: day, hour: hour))!
    }
    private func summary(day: Int, distance: Double?, moving: Double = 600,
                         elevation: Double = 30, thumb: [Coordinate] = []) -> RideSummary {
        let start = date(day)
        return RideSummary(id: UUID(), kind: .navigate, startedAt: start,
                           endedAt: start.addingTimeInterval(moving),
                           hasStats: distance != nil, distanceMeters: distance ?? 0,
                           movingTimeSeconds: distance == nil ? 0 : moving,
                           elevationGainMeters: distance == nil ? 0 : elevation,
                           destinationName: nil, thumbnailCoordinates: thumb)
    }
    private var now: Date { date(24) } // Wed Jun 24 2026; week = Mon 22 … Mon 29 (exclusive)

    @Test func make_derivesWeekAndLastRide() {
        let snap = WidgetSnapshot.make(
            summaries: [summary(day: 22, distance: 1000), summary(day: 24, distance: 2000),
                        summary(day: 21, distance: 5000)],
            goalMeters: 40_000, units: .metric, now: now, calendar: cal)
        #expect(snap.week.distanceMeters == 3000)
        #expect(snap.week.rideCount == 2)
        #expect(snap.week.goalMeters == 40_000)
        #expect(snap.units == .metric)
        #expect(snap.lastRide?.startedAt == date(24))
        #expect(snap.week.start == cal.dateInterval(of: .weekOfYear, for: now)!.start)
        #expect(snap.week.end == cal.dateInterval(of: .weekOfYear, for: now)!.end)
    }

    @Test func make_emptySummaries_nilLastRide_zeroWeek() {
        let snap = WidgetSnapshot.make(summaries: [], goalMeters: 25_000,
                                       units: .imperial, now: now, calendar: cal)
        #expect(snap.lastRide == nil)
        #expect(snap.week.distanceMeters == 0)
        #expect(snap.week.rideCount == 0)
        #expect(snap.week.goalMeters == 25_000)
    }

    @Test func make_statlessMostRecent_carriesHasStatsFalse() {
        let snap = WidgetSnapshot.make(summaries: [summary(day: 24, distance: nil)],
                                       goalMeters: 40_000, units: .imperial, now: now, calendar: cal)
        #expect(snap.lastRide?.hasStats == false)
        #expect(snap.lastRide?.distanceMeters == 0)
    }

    @Test func week_fractionAndPercent_matchWeeklyRideStats() {
        let over = WidgetSnapshot.Week(distanceMeters: 30_000, rideCount: 2,
                                       goalMeters: 25_000, start: now, end: now)
        #expect(abs(over.fraction - 1.0) < 0.0001) // clamped at the goal
        #expect(over.percent == 120)               // uncapped
        let zeroGoal = WidgetSnapshot.Week(distanceMeters: 10, rideCount: 1,
                                           goalMeters: 0, start: now, end: now)
        #expect(zeroGoal.fraction == 0)
        #expect(zeroGoal.percent == 0)
    }

    @Test func weekReset_zeroesWeekKeepsGoalIntervalAndLastRide() {
        let snap = WidgetSnapshot.make(summaries: [summary(day: 24, distance: 5000)],
                                       goalMeters: 40_000, units: .metric, now: now, calendar: cal)
        let reset = snap.weekReset()
        #expect(reset.week.distanceMeters == 0)
        #expect(reset.week.rideCount == 0)
        #expect(reset.week.goalMeters == 40_000)
        #expect(reset.week.start == snap.week.start)
        #expect(reset.week.end == snap.week.end)
        #expect(reset.lastRide == snap.lastRide)
        #expect(reset.generatedAt == snap.generatedAt)
        #expect(reset.units == snap.units)
    }

    @Test func codable_roundTrips() throws {
        let snap = WidgetSnapshot.make(
            summaries: [summary(day: 24, distance: 5000,
                                thumb: [Coordinate(latitude: 40.4, longitude: -79.9),
                                        Coordinate(latitude: 40.5, longitude: -80.0)])],
            goalMeters: 40_000, units: .imperial, now: now, calendar: cal)
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        #expect(decoded == snap)
        #expect(decoded.version == WidgetSnapshot.currentVersion)
        #expect(decoded.lastRide?.thumbnailCoordinates.count == 2)
    }
}
