import Foundation

/// Decodes the SP2 live-broadcast wire envelopes into domain types.
///
/// The `position` and `member_left` broadcasts are produced by the database, not by
/// Swift: migration `0012_record_broadcast` emits the position body via
/// `jsonb_build_object('userID','lat','lon','progressMeters','recordedAt','motionState')`
/// and `0015_member_left` emits `{'userID': ...}`. This decoder is the single, unit-tested
/// home for that field contract, so a rename on either side fails CI instead of silently
/// making peers never appear. The app-target Supabase transport feeds it the broadcast
/// JSON; it reads the body whether the SDK delivers it flat or nested under `"payload"`.
public enum LiveBroadcastDecoder {
    /// Decodes a `position` broadcast (migration 0012). Returns nil on a malformed date,
    /// an unknown motion state, or any missing field.
    public static func position(fromJSON data: Data) -> LivePositionPayload? {
        body(PositionWire.self, fromJSON: data)?.toPayload()
    }

    /// Decodes the departing rider's id from a `member_left` broadcast (migration 0015).
    public static func memberLeft(fromJSON data: Data) -> UUID? {
        body(MemberLeftWire.self, fromJSON: data)?.userID
    }

    /// Reads the wire body whether it arrives flat or nested under a `"payload"` key.
    private static func body<T: Decodable>(_ type: T.Type, fromJSON data: Data) -> T? {
        let decoder = JSONDecoder()
        if let wrapped = try? decoder.decode(Envelope<T>.self, from: data),
           let inner = wrapped.payload {
            return inner
        }
        return try? decoder.decode(type, from: data)
    }

    private struct Envelope<T: Decodable>: Decodable {
        let payload: T?
    }
}

/// Position broadcast body — the migration 0012 `jsonb_build_object` keys, verbatim.
/// `recordedAt` is the raw ISO8601 string the publishing client sent (the DB re-emits it
/// untouched), and `motionState` is a `MotionState` raw value; both are validated in
/// `toPayload()` so a bad value yields nil rather than a partial payload.
private struct PositionWire: Decodable {
    let userID: UUID
    let lat: Double
    let lon: Double
    let progressMeters: Double
    let recordedAt: String
    let motionState: String

    func toPayload() -> LivePositionPayload? {
        // Bare ISO8601 formatter, matching the publisher's encode — created locally
        // because ISO8601DateFormatter is not Sendable (no shared static under Swift 6).
        let iso = ISO8601DateFormatter()
        guard let recorded = iso.date(from: recordedAt),
              let motion = MotionState(rawValue: motionState) else { return nil }
        return LivePositionPayload(
            userID: userID,
            coordinate: Coordinate(latitude: lat, longitude: lon),
            progressMeters: progressMeters,
            recordedAt: recorded,
            motionState: motion)
    }
}

/// member_left broadcast body — migration 0015 emits only the departing rider's id.
private struct MemberLeftWire: Decodable {
    let userID: UUID
}
