import Testing
import Foundation
@testable import AuraCore

/// Pins the SP2 live-broadcast wire contract against the SQL that produces it.
///
/// The `position` and `member_left` broadcasts are emitted by the database, not by
/// Swift: migration `0012_record_broadcast` builds the position envelope with
/// `jsonb_build_object('userID','lat','lon','progressMeters','recordedAt','motionState')`
/// and `0015_member_left` builds `{'userID': ...}`. These tests decode byte-for-byte
/// what those `realtime.send` calls emit, so a rename on either side (a prod-dead bug —
/// peers would silently never appear) fails CI instead of waiting for a two-device ride.
struct LiveBroadcastWireTests {
    private let userID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!

    /// The client publishes recorded_at with a bare ISO8601 formatter and the DB
    /// re-emits that exact string, so the decoder must parse the same shape.
    private let iso = ISO8601DateFormatter()

    /// Mirrors migration 0012's `jsonb_build_object(...)` for the newest point.
    private func positionJSON(userID: String,
                              lat: Double = 37.0,
                              lon: Double = -122.0,
                              progress: Double = 123.4,
                              recordedAt: String,
                              motionState: String,
                              nested: Bool = false) -> Data {
        let inner = """
        {"userID":"\(userID)","lat":\(lat),"lon":\(lon),\
        "progressMeters":\(progress),"recordedAt":"\(recordedAt)","motionState":"\(motionState)"}
        """
        let json = nested ? "{\"payload\":\(inner)}" : inner
        return Data(json.utf8)
    }

    @Test func positionDecodesFlatEnvelope() {
        let recorded = Date(timeIntervalSince1970: 1_700_000_000)
        let data = positionJSON(userID: userID.uuidString,
                                recordedAt: iso.string(from: recorded),
                                motionState: "moving")
        let payload = LiveBroadcastDecoder.position(fromJSON: data)
        #expect(payload?.userID == userID)
        #expect(payload?.coordinate.latitude == 37.0)
        #expect(payload?.coordinate.longitude == -122.0)
        #expect(payload?.progressMeters == 123.4)
        #expect(payload?.recordedAt == recorded)
        #expect(payload?.motionState == .moving)
    }

    @Test func positionDecodesNestedPayloadEnvelope() {
        // Some SDK versions deliver the broadcast body nested under "payload".
        let recorded = Date(timeIntervalSince1970: 1_700_000_000)
        let data = positionJSON(userID: userID.uuidString,
                                recordedAt: iso.string(from: recorded),
                                motionState: "stopped",
                                nested: true)
        let payload = LiveBroadcastDecoder.position(fromJSON: data)
        #expect(payload?.userID == userID)
        #expect(payload?.motionState == .stopped)
        #expect(payload?.recordedAt == recorded)
    }

    @Test func positionRejectsUnknownMotionState() {
        let data = positionJSON(userID: userID.uuidString,
                                recordedAt: iso.string(from: Date()),
                                motionState: "sprinting")
        #expect(LiveBroadcastDecoder.position(fromJSON: data) == nil)
    }

    @Test func positionRejectsMalformedDate() {
        let data = positionJSON(userID: userID.uuidString,
                                recordedAt: "not-a-date",
                                motionState: "moving")
        #expect(LiveBroadcastDecoder.position(fromJSON: data) == nil)
    }

    @Test func positionRejectsMissingField() {
        // No motionState key at all.
        let json = """
        {"userID":"\(userID.uuidString)","lat":37.0,"lon":-122.0,\
        "progressMeters":1.0,"recordedAt":"\(iso.string(from: Date()))"}
        """
        #expect(LiveBroadcastDecoder.position(fromJSON: Data(json.utf8)) == nil)
    }

    @Test func memberLeftDecodesFlatEnvelope() {
        let data = Data("{\"userID\":\"\(userID.uuidString)\"}".utf8)
        #expect(LiveBroadcastDecoder.memberLeft(fromJSON: data) == userID)
    }

    @Test func memberLeftDecodesNestedPayloadEnvelope() {
        let data = Data("{\"payload\":{\"userID\":\"\(userID.uuidString)\"}}".utf8)
        #expect(LiveBroadcastDecoder.memberLeft(fromJSON: data) == userID)
    }

    @Test func memberLeftRejectsMissingUserID() {
        #expect(LiveBroadcastDecoder.memberLeft(fromJSON: Data("{}".utf8)) == nil)
    }
}
