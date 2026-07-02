import Testing
import Foundation
import AuraCore
@testable import AuraKit

@Suite struct WeeklyGlanceTests {
    private let now = Date(timeIntervalSince1970: 1_750_000_000) // fixed
    private func summary(_ meters: Double, daysAgo: Int) -> RideSummary {
        RideSummary(id: UUID(), kind: .freeRide,
                    startedAt: now.addingTimeInterval(Double(-daysAgo) * 86_400),
                    endedAt: now, hasStats: true, distanceMeters: meters,
                    movingTimeSeconds: 1800, elevationGainMeters: 50,
                    destinationName: nil, thumbnailCoordinates: [])
    }

    @Test func noRidesNoLast_promptsFirstRide() {
        let s = WeeklyGlance.headline(week: .zero, goalMeters: 40_000, lastRide: nil,
                                      units: .imperial, now: now)
        #expect(s == "Plan your first ride to start your weekly goal")
    }

    @Test func noRidesThisWeek_showsLastRideDistanceAndDay() {
        let last = summary(29_600, daysAgo: 1) // ~18.4 mi, yesterday
        let s = WeeklyGlance.headline(week: .zero, goalMeters: 40_000, lastRide: last,
                                      units: .imperial, now: now)
        #expect(s == "18.4 mi last ride, yesterday")
    }

    @Test func underGoalMidWeek_showsDistanceRemaining() {
        let week = WeeklyRideStats(distanceMeters: 29_600, rideCount: 1,
                                   elevationGainMeters: 50, movingTimeSeconds: 1800)
        let s = WeeklyGlance.headline(week: week, goalMeters: 40_000, lastRide: summary(29_600, daysAgo: 1),
                                      units: .imperial, now: now)
        #expect(s == "6.5 mi to your weekly goal") // (40000-29600)m = 10400m ≈ 6.5 mi
    }

    @Test func atOrOverGoal_showsComplete() {
        let week = WeeklyRideStats(distanceMeters: 80_000, rideCount: 5,
                                   elevationGainMeters: 0, movingTimeSeconds: 0)
        let s = WeeklyGlance.headline(week: week, goalMeters: 40_000, lastRide: nil,
                                      units: .imperial, now: now)
        #expect(s == "Weekly goal complete — 200%")
    }

    @Test func ringFractionClampsToOne() {
        let week = WeeklyRideStats(distanceMeters: 80_000, rideCount: 5,
                                   elevationGainMeters: 0, movingTimeSeconds: 0)
        #expect(WeeklyGlance.ringFraction(week: week, goalMeters: 40_000) == 1.0)
    }
}
