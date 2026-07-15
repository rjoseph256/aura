import Foundation
import Supabase
import AuraCore
import AuraKit

/// Live Supabase implementation of GroupRideBackend. All writes go through the
/// SECURITY DEFINER RPCs; RLS enforces members-only reads. `nonisolated` because
/// it is pure backend I/O (no main-actor state) under default-MainActor isolation.
public nonisolated struct SupabaseGroupRideBackend: GroupRideBackend {
    private let client: SupabaseClient
    public init(client: SupabaseClient = SupabaseClientProvider.shared) { self.client = client }

    public nonisolated func signIn(idToken: String, nonce: String, displayName: String?) async throws {
        try await client.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce))
        if let displayName {
            _ = try await client.rpc("upsert_display_name", params: ["p_name": displayName]).execute()
        }
    }
    public nonisolated func renameDisplayName(_ name: String) async throws {
        _ = try await client.rpc("upsert_display_name", params: ["p_name": name]).execute()
    }
    public nonisolated func currentUserID() async throws -> UUID {
        try await client.auth.session.user.id
    }
    public nonisolated func createRide(route: Data) async throws -> GroupRide {
        // Decode the route bytes into a JSON value so p_route arrives as real jsonb
        // (an object), not a quoted JSON string.
        let routeJSON = try JSONDecoder().decode(AnyJSON.self, from: route)
        do {
            let row: GroupRideRow = try await client
                .rpc("create_ride", params: ["p_route": routeJSON])
                .single().execute().value
            return try row.toDomain()
        } catch let error as PostgrestError where error.message.contains("rides_route_check")
                                              || error.message.lowercased().contains("check constraint") {
            throw GroupRideError.routeTooLarge
        }
    }
    public nonisolated func joinRide(code: JoinCode) async throws -> JoinedRide {
        do {
            let row: GroupRideRow = try await client
                .rpc("join_ride", params: ["p_code": code.rawValue]).single().execute().value
            return JoinedRide(ride: try row.toDomain(), route: try row.routeData())
        } catch { throw GroupRideError.joinFailed }
    }
    public nonisolated func roster(rideID: UUID) async throws -> [RosterMember] {
        let rows: [RosterRow] = try await client
            .rpc("ride_roster", params: ["p_ride_id": rideID.uuidString]).execute().value
        return rows.map { RosterMember(userID: $0.userID, displayName: $0.displayName,
                                       role: $0.role == "host" ? .host : .member) }
    }
    public nonisolated func recordTrackPoints(rideID: UUID, points: [RemoteTrackPoint]) async throws {
        // Heterogeneous params (String + array) must be built as AnyJSON, not a
        // [String: Any] dictionary (which is not Encodable and will not compile).
        let payload: [AnyJSON] = points.map { p in
            .object([
                "recorded_at": .string(ISO8601DateFormatter().string(from: p.recordedAt)),
                "lat": .double(p.coordinate.latitude),
                "lon": .double(p.coordinate.longitude),
                "progress_meters": .double(p.progressMeters)
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
        _ = try await client.functions.invoke("delete-account")
    }

    // MARK: - Auth-state seam (added Task 2)

    public nonisolated var cachedUserID: UUID? { client.auth.currentSession?.user.id }

    public nonisolated func authEvents() -> AsyncStream<AuthChange> {
        AsyncStream { continuation in
            let task = Task {
                for await (event, session) in client.auth.authStateChanges {
                    switch event {
                    case .signedIn, .tokenRefreshed, .initialSession:
                        if let id = session?.user.id { continuation.yield(.signedIn(id)) } else { continuation.yield(.signedOut) }
                    case .signedOut, .userDeleted:
                        continuation.yield(.signedOut)
                    default: break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public nonisolated func signOut() async throws { try await client.auth.signOut() }
}

/// Wire row returned by create_ride / join_ride. CodingKeys map snake_case JSON
/// to camelCase properties (avoids SwiftLint `identifier_name`); the PostgREST
/// decoder does no key conversion of its own.
private nonisolated struct GroupRideRow: Decodable {
    let id: UUID
    let hostID: UUID
    let joinCode: String
    let status: String
    let createdAt: Date
    let route: AnyJSON
    enum CodingKeys: String, CodingKey {
        case id, status, route
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
    func routeData() throws -> Data {
        try JSONEncoder().encode(route)
    }
}

/// Wire row returned by ride_roster. CodingKeys map snake_case JSON to camelCase
/// properties, matching the GroupRideRow convention above.
private nonisolated struct RosterRow: Decodable {
    let userID: UUID
    let displayName: String
    let role: String
    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case displayName = "display_name"
        case role
    }
}
