import Foundation

/// The Realtime broadcast topic for a ride — the single home for that string, next to
/// `LiveBroadcastDecoder`, which owns the body contract for the same messages.
///
/// The database is the publisher: `record_track_points`, `leave_ride`, and `end_ride` all
/// call `realtime.send(..., 'ride:' || p_ride_id::text, true)`. Postgres renders
/// `uuid::text` in lowercase, so the topic MUST be lowercased here — Swift's
/// `UUID.uuidString` is uppercase and Realtime topics are case-sensitive. Subscribing with
/// the raw `uuidString` silently receives nothing: publishing still works (the RPC takes
/// the id as a parameter, which Postgres parses case-insensitively), so the failure shows
/// up only as peers who never appear on a real multi-device ride.
public enum RideTopic {
    /// `ride:<lowercased uuid>` — byte-for-byte what the emitting SQL broadcasts to.
    public static func name(rideID: UUID) -> String {
        "ride:\(rideID.uuidString.lowercased())"
    }
}
