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
    public nonisolated func createRide(route: Data?) async throws -> GroupRide {
        // Decode the route bytes into a JSON value so p_route arrives as real jsonb
        // (an object), not a quoted JSON string.
        //
        // An open ride (nil) **omits the argument entirely** rather than sending
        // `AnyJSON.null` (ROH-114). Sending null would store the jsonb scalar `'null'`, which
        // is not SQL NULL: it satisfies `is not null`, has a non-zero `pg_column_size`, and
        // would come back as four bytes on the next join. Omitting it lets `create_ride`'s
        // `p_route jsonb default null` supply a real SQL NULL.
        let params = try route.map { ["p_route": try JSONDecoder().decode(AnyJSON.self, from: $0)] } ?? [:]
        do {
            let row: GroupRideRow = try await client
                .rpc("create_ride", params: params)
                .single().execute().value
            return try row.toDomain()
        } catch let error as PostgrestError where error.message.contains("rides_route_check")
                                              || error.message.lowercased().contains("check constraint") {
            throw GroupRideError.routeTooLarge
        } catch let error where EntryFailure.isConnectionFailure(error) {
            throw GroupRideError.connectionFailed
        }
    }
    public nonisolated func joinRide(code: JoinCode) async throws -> JoinedRide {
        do {
            let row: GroupRideRow = try await client
                // p_supports_open declares this build understands a route-less ride (ROH-114).
                // A build predating migration 0021 omits it, the default false applies, and the
                // server refuses the join rather than handing back a route it cannot decode.
                .rpc("join_ride", params: ["p_code": AnyJSON.string(code.rawValue),
                                           "p_supports_open": AnyJSON.bool(true)])
                .single().execute().value
            return JoinedRide(ride: try row.toDomain(), route: try row.routeData())
        } catch is CancellationError {
            // Rethrow cancellation untouched so the catch-all can never misreport it as a
            // rejection. Scope honestly: URLSession surfaces MID-FLIGHT cancellation as
            // URLError(.cancelled) — which the reachability catch below maps to
            // .connectionFailed — so this clause guards the narrower raw-CancellationError
            // paths (PostgREST's pre-dispatch Task.checkCancellation, auth internals),
            // where withTimeout's CancellationError → TimeoutError conversion still applies
            // (ROH-231 review trace).
            throw CancellationError()
        } catch let error where EntryFailure.isConnectionFailure(error) {
            throw GroupRideError.connectionFailed
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
    public nonisolated func startRide(rideID: UUID) async throws {
        _ = try await client.rpc("start_ride", params: ["p_ride_id": rideID.uuidString]).execute()
    }
    public nonisolated func rideStatus(rideID: UUID) async throws -> RideLifecycleStatus {
        let row: RideStatusRow = try await client
            .rpc("ride_status", params: ["p_ride_id": rideID.uuidString]).single().execute().value
        return RideLifecycleStatus(hostID: row.hostID, startedAt: row.startedAt, endedAt: row.endedAt)
    }
    public nonisolated func endRide(rideID: UUID) async throws {
        // Map the server's `not host` raise to the typed error so GroupRideSession's
        // already-gone-is-success retry branch fires in production (ROH-68). A lost-response
        // retry, a host transfer, or a swept ride all surface as `not host` here — all mean
        // "already gone", not a transient failure to keep retrying.
        do {
            _ = try await client.rpc("end_ride", params: ["p_ride_id": rideID.uuidString]).execute()
        } catch let error as PostgrestError where error.message.contains("not host") {
            throw GroupRideError.notHost
        }
    }
    public nonisolated func leaveRide(rideID: UUID) async throws {
        // Map the server's `not a member` raise to the typed error so the already-gone-is-success
        // retry branch fires in production (ROH-68): a lost-response retry after the membership
        // row is already deleted raises `not a member`, which means "already left", not a failure.
        do {
            _ = try await client.rpc("leave_ride", params: ["p_ride_id": rideID.uuidString]).execute()
        } catch let error as PostgrestError where error.message.contains("not a member") {
            throw GroupRideError.notMember
        }
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
    /// Optional, and `routeData()` also folds `.null` away — see there. ROH-114.
    let route: AnyJSON?
    /// Optional, and decoded as a `String` rather than a `GroupRide.Kind` — both deliberate, and
    /// `resolvedKind` is where the two decisions are argued. ROH-114.
    let kind: String?
    let startedAt: Date?
    let endedAt: Date?
    enum CodingKeys: String, CodingKey {
        case id, status, route, kind
        case hostID = "host_id"
        case joinCode = "join_code"
        case createdAt = "created_at"
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }
    func toDomain() throws -> GroupRide {
        guard let code = JoinCode(rawValue: joinCode),
              let rideStatus = GroupRide.Status(rawValue: status) else {
            throw GroupRideError.joinFailed
        }
        return GroupRide(id: id, hostID: hostID, joinCode: code, kind: resolvedKind, status: rideStatus,
                         createdAt: createdAt, startedAt: startedAt, endedAt: endedAt)
    }

    /// The ride's kind, resolved so that **no shape of this column can fail a join** (ROH-114).
    ///
    /// Both fallbacks below exist because the only caller that can observe them is `joinRide`, whose
    /// blanket `catch` turns anything thrown here into "double-check the code with your host" — a
    /// message that is wrong about a correct code and says nothing about what to actually do.
    ///
    /// **Absent** — a project that has not had migration 0021 applied returns no `kind` at all. A
    /// required key would then fail to decode *every* ride, route rides included. Absent falls back
    /// by looking at the route, and it falls **toward `.open`** when the route is absent too:
    /// migration 0022 constrains `(kind = 'open') = (route is null or route = 'null'::jsonb)`, so
    /// kind-absent with route-absent is unambiguous, and guessing `.route` there would fork the
    /// rider (D4.1) into a navigate container with no route — the "Couldn't load this ride's route."
    /// dead end. Guessing wrong toward the error screen is the one wrong guess with a cost.
    ///
    /// **Unknown** — a newer server sending a third kind this build has never heard of. That maps to
    /// `.route` rather than throwing: a guest should not be ejected from a ride they just joined
    /// because of a value they could safely have ignored, and `.route` is the conservative reading
    /// of a ride that *has* a route (the absent-route case cannot reach here — 0022 forbids a
    /// non-`open` kind without one).
    ///
    /// None of this is rollout safety in both directions, and it should not be sold as such: against
    /// a pre-0021 project `joinRide` sends `p_supports_open`, which PostgREST cannot even resolve to
    /// a function. Applying the migrations before the build ships is what protects the rollout.
    private var resolvedKind: GroupRide.Kind {
        guard let kind else { return routeIsAbsent ? .open : .route }
        return GroupRide.Kind(rawValue: kind) ?? .route
    }

    /// Whether this row carries no route, folding the jsonb `'null'` scalar in with a real absence
    /// exactly as `routeData()` does — the same rule migration 0022's CHECK is written against.
    private var routeIsAbsent: Bool {
        switch route {
        case .none, .some(.null): true
        default: false
        }
    }
    /// nil for a destination-free ride (ROH-114), and **`.null` folds to nil too**.
    ///
    /// The rule itself lives in `AuraCore.RouteEnvelope`, which carries the full account of why
    /// `.null` has to fold. It was moved there because this type is `private` in a target whose
    /// only test bundle is `AuraUITests`, so the layer that the first spec revision got wrong —
    /// the one that showed every guest of an open ride an error and then removed them from the
    /// ride — was the one layer no test could reach. What is left here is the wire mapping.
    func routeData() throws -> Data? {
        try RouteEnvelope.routeData(route.map(Self.routeJSON))
    }

    /// `AnyJSON`'s seven cases into AuraCore's mirror of them, one for one.
    ///
    /// The package cannot see `AnyJSON` — it is an SDK type of this target — so the translation
    /// has to happen here, and it has to be complete: `.object` and `.array` recurse, and
    /// `.integer` stays an integer rather than being widened into `.double`, which would quietly
    /// round any value past 2^53 inside a payload this path promises to carry unchanged.
    private static func routeJSON(_ json: AnyJSON) -> RouteJSON {
        switch json {
        case .null: .null
        case .bool(let value): .bool(value)
        case .integer(let value): .integer(value)
        case .double(let value): .double(value)
        case .string(let value): .string(value)
        case .object(let value): .object(value.mapValues(Self.routeJSON))
        case .array(let value): .array(value.map(Self.routeJSON))
        }
    }
}

/// Wire row returned by ride_status. CodingKeys map snake_case JSON to camelCase
/// properties, matching the GroupRideRow convention above.
private nonisolated struct RideStatusRow: Decodable {
    let hostID: UUID
    let startedAt: Date?
    let endedAt: Date?
    enum CodingKeys: String, CodingKey {
        case hostID = "host_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
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
