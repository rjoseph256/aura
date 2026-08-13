import Testing
import Foundation
@testable import AuraKit
import AuraCore

/// A system clock step must not stop a rider publishing their position to the crew (ROH-151).
///
/// The cadence used to subtract two `Date`s, the shape ROH-130's D6 replaced in the Live Activity
/// push policy. Each fixture below failed against that code and passes against this one.
///
/// **No fixture-level negative control here, deliberately.** The obvious one — asserting that
/// `stepped.date - published.date` reads as "not due" while the monotonic halves read as "due" —
/// tests `RideInstant.stepped`, which is defined in this target. A mutation run restoring the old
/// wall-clock cadence failed the fixtures below and left such a control green, so it would pin
/// nothing. What makes these honest is that they exercise `publishIfDue` end to end.
///
/// ROH-148 (presence staleness through a clock step) is NOT covered here and is not fixed: it
/// compares against a wire timestamp, which no client-side clock swap can repair. See ROH-152.
@MainActor
struct GroupRideClockStepTests {
    private let me = UUID()
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func makeSession(_ transport: InMemoryRideSessionTransport) -> RideSession {
        RideSession(rideID: UUID(), selfUserID: me, transport: transport,
                    cadence: LiveShareCadence(foregroundInterval: .seconds(2), droppedTimeout: 40))
    }

    private func point(_ session: RideSession, at instant: RideInstant) {
        session.locationDidUpdate(coordinate: Coordinate(latitude: 1, longitude: 1),
                                  progressMeters: 10, speed: 5, at: instant.date)
    }

    /// An NTP correction that yanks the wall clock back an hour used to silence this rider for a
    /// full hour: `now.timeIntervalSince(lastPublish)` went negative, so the cadence guard failed
    /// for the width of the step and nothing left the outbox.
    @Test func backwardWallClockStepKeepsPublishing() async {
        let transport = InMemoryRideSessionTransport()
        let session = makeSession(transport)
        await session.start(roster: [])

        let start = RideInstant.coherent(t0)
        point(session, at: start)
        await session.publishIfDue(now: start, lifecycle: .foreground)
        #expect(transport.publishedBatches.count == 1)

        let afterStep = RideInstant.stepped(t0.addingTimeInterval(3), by: -3600)
        point(session, at: afterStep)
        await session.publishIfDue(now: afterStep, lifecycle: .foreground)
        #expect(transport.publishedBatches.count == 2)

        session.stop()
    }

    /// The mirror case, and the reason this is not simply "publish unconditionally": a *forward*
    /// step must not let a batch out early either, or the cadence the backend is sized for stops
    /// being a cadence.
    @Test func forwardWallClockStepDoesNotPublishEarly() async {
        let transport = InMemoryRideSessionTransport()
        let session = makeSession(transport)
        await session.start(roster: [])

        let start = RideInstant.coherent(t0)
        point(session, at: start)
        await session.publishIfDue(now: start, lifecycle: .foreground)
        #expect(transport.publishedBatches.count == 1)

        let afterStep = RideInstant.stepped(t0.addingTimeInterval(0.5), by: 3600)
        point(session, at: afterStep)
        await session.publishIfDue(now: afterStep, lifecycle: .foreground)
        #expect(transport.publishedBatches.count == 1)

        session.stop()
    }

    /// The throttle still holds with no step in play, so the fix cannot be "the guard is gone".
    @Test func theThrottleStillHoldsInsideTheInterval() async {
        let transport = InMemoryRideSessionTransport()
        let session = makeSession(transport)
        await session.start(roster: [])

        let start = RideInstant.coherent(t0)
        point(session, at: start)
        await session.publishIfDue(now: start, lifecycle: .foreground)
        #expect(transport.publishedBatches.count == 1)

        let soon = RideInstant.coherent(t0.addingTimeInterval(0.5))
        point(session, at: soon)
        await session.publishIfDue(now: soon, lifecycle: .foreground)
        #expect(transport.publishedBatches.count == 1)

        session.stop()
    }
}
