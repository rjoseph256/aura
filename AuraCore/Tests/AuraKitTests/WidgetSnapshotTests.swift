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
            goalMeters: 40_000, units: .metric, now: now, activeRideID: nil, calendar: cal)
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
                                       units: .imperial, now: now, activeRideID: nil, calendar: cal)
        #expect(snap.lastRide == nil)
        #expect(snap.week.distanceMeters == 0)
        #expect(snap.week.rideCount == 0)
        #expect(snap.week.goalMeters == 25_000)
    }

    @Test func make_statlessMostRecent_carriesHasStatsFalse() {
        let snap = WidgetSnapshot.make(summaries: [summary(day: 24, distance: nil)],
                                       goalMeters: 40_000, units: .imperial, now: now, activeRideID: nil, calendar: cal)
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
                                       goalMeters: 40_000, units: .metric, now: now, activeRideID: nil, calendar: cal)
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
            goalMeters: 40_000, units: .imperial, now: now, activeRideID: nil, calendar: cal)
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        #expect(decoded == snap)
        #expect(decoded.version == WidgetSnapshot.currentVersion)
        #expect(decoded.lastRide?.thumbnailCoordinates.count == 2)
    }

    /// The exclusion is by id, not by "is it unfinished". A rider who recovered an unfinished
    /// ride earlier this week and starts a ride today has two unfinished rows; only the one they
    /// are on should leave Home. A Bool-shaped rule hides both and drops the earlier ride's
    /// distance from the week-to-date ring for the whole of today's ride.
    @Test func onlyTheActiveRideIsExcluded() {
        // Sunday 2025-06-15. With the suite's firstWeekday = 2 calendar, the week is
        // Mon 2025-06-09 ..< Mon 2025-06-16, so `earlier` (Sat 2025-06-14) is inside it.
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let interval = cal.dateInterval(of: .weekOfYear, for: now)!
        let earlier = RideSummary(id: UUID(), kind: .freeRide, startedAt: now.addingTimeInterval(-86_400),
                                  endedAt: now.addingTimeInterval(-80_000), hasStats: true,
                                  distanceMeters: 10_000, movingTimeSeconds: 1_800, pausedSeconds: 0,
                                  checkpointedAt: now.addingTimeInterval(-80_000),
                                  elevationGainMeters: 100, destinationName: nil,
                                  thumbnailCoordinates: [])
        let today = RideSummary(id: UUID(), kind: .freeRide, startedAt: now.addingTimeInterval(-600),
                                endedAt: now, hasStats: true,
                                distanceMeters: 5_000, movingTimeSeconds: 600, pausedSeconds: 0,
                                checkpointedAt: now, elevationGainMeters: 20, destinationName: nil,
                                thumbnailCoordinates: [])
        // Confirm the fixture actually sits inside the resolved week before trusting the assertions below.
        #expect(interval.contains(earlier.startedAt))
        #expect(interval.contains(today.startedAt))

        let snapshot = WidgetSnapshot.make(summaries: [earlier, today], goalMeters: 40_000,
                                           units: .metric, now: now, activeRideID: today.id,
                                           calendar: cal)

        #expect(snapshot.lastRide?.id == earlier.id, "the in-flight ride must not own the slot")
        #expect(snapshot.week.distanceMeters == 10_000, "the earlier ride still counts")
        #expect(snapshot.week.rideCount == 1)
    }

    /// A payload written by the previous app version has none of the new keys. Swift's
    /// synthesized `Codable` decodes a missing key for an Optional as nil, which is the safe
    /// reading: not a checkpoint, no duration pair, no paused time.
    ///
    /// This is why `currentVersion` stays 1. Bumping it would make `WidgetSnapshotStore.read()`
    /// reject the stored payload, and the only writer is in the app target — so both widgets
    /// would render "No rides yet" with the ring at 0% until the rider next foregrounds Aura,
    /// which for a widget user can be days.
    @Test func aPayloadWrittenWithoutTheNewFieldsStillDecodes() throws {
        let json = """
        {"version":1,"generatedAt":749000000,"units":"metric",
         "lastRide":{"id":"00000000-0000-0000-0000-000000000001","kind":"freeRide",
                     "startedAt":748000000,"hasStats":true,"distanceMeters":20000,
                     "movingTimeSeconds":3720,"elevationGainMeters":104,
                     "thumbnailCoordinates":[]},
         "week":{"distanceMeters":20000,"rideCount":3,"goalMeters":40000,
                 "start":748000000,"end":749000000}}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: json)
        let ride = try #require(decoded.lastRide)
        #expect(ride.checkpointedAt == nil)
        #expect(ride.endedAt == nil)
        #expect(ride.pausedSeconds == nil)
        #expect(!ride.isUnfinished, "a payload from before this field must not read as unfinished")
    }

    /// `RideSummary.isUnfinished` and `LastRide.isUnfinished` are deliberately different
    /// expressions — the widget struct needs the `pausedSeconds` provenance guard and the summary
    /// does not. Nothing else stops them drifting apart.
    @Test func theWidgetPredicateAgreesWithTheSummaryPredicate() {
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        func summary(endedAt: Date?, checkpointedAt: Date?) -> RideSummary {
            RideSummary(id: UUID(), kind: .freeRide, startedAt: base, endedAt: endedAt,
                        hasStats: true, distanceMeters: 1_000, movingTimeSeconds: 300,
                        pausedSeconds: 0, checkpointedAt: checkpointedAt,
                        elevationGainMeters: 10, destinationName: nil, thumbnailCoordinates: [])
        }
        for s in [summary(endedAt: base, checkpointedAt: nil),
                  summary(endedAt: base, checkpointedAt: base),
                  summary(endedAt: nil, checkpointedAt: nil)] {
            #expect(WidgetSnapshot.LastRide(s).isUnfinished == s.isUnfinished)
        }
    }
}
