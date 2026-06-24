import XCTest
import AuraCore
@testable import AuraKit

final class RideAggregatorTests: XCTestCase {

    // A fixed Monday-start UTC calendar so "this week" is deterministic across machines.
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2 // Monday
        return c
    }()

    private func date(_ day: Int, hour: Int = 12) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 6, day: day, hour: hour))!
    }

    private func ride(day: Int, distance: Double?, elevation: Double = 30, moving: Double = 600) -> Ride {
        let start = date(day)
        let stats = distance.map {
            RideStats(distanceMeters: $0, movingTimeSeconds: moving,
                      averageSpeedMetersPerSecond: 5, maxSpeedMetersPerSecond: 8,
                      elevationGainMeters: elevation)
        }
        return Ride(kind: .navigate, startedAt: start, endedAt: start.addingTimeInterval(moving),
                    track: [], stats: stats, routeId: nil, destinationPlaceId: nil)
    }

    // now = Wed Jun 24 2026 → week is Mon Jun 22 … Sun Jun 28.
    private var now: Date { date(24) }

    func test_weekToDate_sumsOnlyInWeekRides() {
        let rides = [
            ride(day: 22, distance: 1000),  // Mon — in week
            ride(day: 24, distance: 2000),  // Wed (today) — in week
            ride(day: 21, distance: 5000),  // Sun — previous week
            ride(day: 29, distance: 9000),  // next Mon — next week
        ]
        let w = RideAggregator.weekToDate(rides, now: now, calendar: cal)
        XCTAssertEqual(w.distanceMeters, 3000, accuracy: 0.001)
        XCTAssertEqual(w.rideCount, 2)
        XCTAssertEqual(w.elevationGainMeters, 60, accuracy: 0.001)
        XCTAssertEqual(w.movingTimeSeconds, 1200, accuracy: 0.001)
    }

    func test_weekToDate_rideWithoutStats_countsButAddsNoDistance() {
        let rides = [ride(day: 23, distance: 1500), ride(day: 24, distance: nil)]
        let w = RideAggregator.weekToDate(rides, now: now, calendar: cal)
        XCTAssertEqual(w.rideCount, 2)
        XCTAssertEqual(w.distanceMeters, 1500, accuracy: 0.001)
    }

    func test_weekToDate_empty_isZero() {
        XCTAssertEqual(RideAggregator.weekToDate([], now: now, calendar: cal), .zero)
    }

    func test_mostRecent_returnsLatestStart() {
        let rides = [ride(day: 22, distance: 1), ride(day: 28, distance: 1), ride(day: 24, distance: 1)]
        XCTAssertEqual(RideAggregator.mostRecent(rides)?.startedAt, date(28))
    }

    func test_mostRecent_empty_isNil() {
        XCTAssertNil(RideAggregator.mostRecent([]))
    }

    func test_goalFraction_clampsToOne_andPercentIsUncapped() {
        let w = WeeklyRideStats(distanceMeters: 5000, rideCount: 2,
                                elevationGainMeters: 0, movingTimeSeconds: 0)
        XCTAssertEqual(w.goalFraction(goalMeters: 4000), 1.0, accuracy: 0.001) // clamped
        XCTAssertEqual(w.goalPercent(goalMeters: 4000), 125)                   // uncapped
    }

    func test_goalFraction_partial() {
        let w = WeeklyRideStats(distanceMeters: 3000, rideCount: 1,
                                elevationGainMeters: 0, movingTimeSeconds: 0)
        XCTAssertEqual(w.goalFraction(goalMeters: 4000), 0.75, accuracy: 0.001)
    }

    func test_goalFraction_zeroGoal_isSafe() {
        let w = WeeklyRideStats(distanceMeters: 3000, rideCount: 1,
                                elevationGainMeters: 0, movingTimeSeconds: 0)
        XCTAssertEqual(w.goalFraction(goalMeters: 0), 0)
        XCTAssertEqual(w.goalPercent(goalMeters: 0), 0)
    }
}
