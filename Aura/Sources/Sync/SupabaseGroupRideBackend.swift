import Foundation
import Supabase
import AuraCore
import AuraKit

/// Live Supabase implementation of GroupRideBackend. All writes go through the
/// SECURITY DEFINER RPCs; RLS enforces members-only reads.
public struct SupabaseGroupRideBackend: GroupRideBackend {
    private let client: SupabaseClient
    public init(client: SupabaseClient = SupabaseClientProvider.shared) { self.client = client }

    public nonisolated func signIn(idToken: String, nonce: String, displayName: String?) async throws {
        try await client.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce))
        if let displayName {
            _ = try await client.rpc("upsert_display_name", params: ["p_name": displayName]).execute()
        }
    }
    public nonisolated func createRide(route: Data) async throws -> GroupRide {
        let row: GroupRideRow = try await client
            .rpc("create_ride", params: ["p_route": AnyJSON.string(String(decoding: route, as: UTF8.self))])
            .single().execute().value
        return try row.toDomain()
    }
    public nonisolated func joinRide(code: JoinCode) async throws -> GroupRide {
        do {
            let row: GroupRideRow = try await client
                .rpc("join_ride", params: ["p_code": code.rawValue]).single().execute().value
            return try row.toDomain()
        } catch { throw GroupRideError.joinFailed }
    }
    public nonisolated func recordTrackPoints(rideID: UUID, points: [RemoteTrackPoint]) async throws {
        // Heterogeneous params (String + array) must be built as AnyJSON, not a
        // [String: Any] dictionary (which is not Encodable and will not compile).
        let payload: [AnyJSON] = points.map { p in
            .object([
                "recorded_at": .string(ISO8601DateFormatter().string(from: p.recordedAt)),
                "lat": .double(p.coordinate.latitude),
                "lon": .double(p.coordinate.longitude),
                "progress_meters": .double(p.progressMeters),
            ])
        }
        _ = try await client.rpc("record_track_points",
            params: ["p_ride_id": AnyJSON.string(rideID.uuidString),
                     "p_points": AnyJSON.array(payload)]).execute()
    }
    public nonisolated func endRide(rideID: UUID) async throws {
        _ = try await client.rpc("end_ride", params: ["p_ride_id": rideID.uuidString]).execute()
    }
    public nonisolated func leaveRide(rideID: UUID) async throws {
        _ = try await client.rpc("leave_ride", params: ["p_ride_id": rideID.uuidString]).execute()
    }
    public nonisolated func deleteAccount() async throws {
        _ = try await client.rpc("delete_account").execute()
    }
}

/// Wire row returned by create_ride / join_ride. CodingKeys map snake_case JSON
/// to camelCase properties (avoids SwiftLint `identifier_name`); the PostgREST
/// decoder does no key conversion of its own.
private struct GroupRideRow: Decodable {
    let id: UUID
    let hostID: UUID
    let joinCode: String
    let status: String
    let createdAt: Date
    enum CodingKeys: String, CodingKey {
        case id, status
        case hostID = "host_id"
        case joinCode = "join_code"
        case createdAt = "created_at"
    }
    func toDomain() throws -> GroupRide {
        guard let code = JoinCode(rawValue: joinCode),
              let rideStatus = GroupRide.Status(rawValue: status) else {
            throw GroupRideError.joinFailed
        }
        return GroupRide(id: id, hostID: hostID, joinCode: code, status: rideStatus, createdAt: createdAt)
    }
}
