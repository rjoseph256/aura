import Testing
import Foundation
@testable import AuraCore

/// Pins the Realtime broadcast TOPIC against the SQL that publishes to it.
///
/// `public.record_track_points` (and `leave_ride`/`end_ride`) broadcast with
/// `realtime.send(..., 'ride:' || p_ride_id::text, true)`. Postgres renders `uuid::text`
/// in LOWERCASE, while Swift's `UUID.uuidString` is UPPERCASE — and Realtime topics are
/// case-sensitive. Building the subscribe topic with `uuidString` therefore subscribed to
/// a topic nothing ever published to: every publish succeeded (the RPC takes the id as a
/// parameter, and Postgres parses uuids case-insensitively) while every peer broadcast was
/// silently missed, so riders never saw each other on a real two-device ride.
///
/// These tests exist because the app-target transport that builds the topic is not
/// unit-testable, so the string it produces is pinned here instead.
struct RideTopicTests {
    private let rideID = UUID(uuidString: "EBC47D0D-6B31-4291-A214-3973C412942C")!

    /// Byte-for-byte what `'ride:' || p_ride_id::text` emits in Postgres.
    @Test func matchesTheTopicPostgresBroadcastsTo() {
        #expect(RideTopic.name(rideID: rideID) == "ride:ebc47d0d-6b31-4291-a214-3973c412942c")
    }

    /// The specific regression: `uuidString` is uppercase, so it must NOT be used raw.
    @Test func isLowercasedNotRawUUIDString() {
        let topic = RideTopic.name(rideID: rideID)
        #expect(topic == topic.lowercased())
        #expect(topic != "ride:\(rideID.uuidString)")
    }

    /// The RLS policy on `realtime.messages` gates on `realtime.topic() ~~ 'ride:%'`, and
    /// `ride_id_from_topic` recovers the id via `substring(p_topic from 6)::uuid`.
    @Test func carriesThePrefixAndIDTheRLSPolicyParses() {
        let topic = RideTopic.name(rideID: rideID)
        #expect(topic.hasPrefix("ride:"))
        #expect(UUID(uuidString: String(topic.dropFirst(5))) == rideID)
    }
}
