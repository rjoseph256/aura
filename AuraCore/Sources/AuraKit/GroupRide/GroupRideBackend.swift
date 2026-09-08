import Foundation
import AuraCore

public enum GroupRideError: Error, Equatable, Sendable {
    case notAuthenticated
    case joinFailed       // generic: wrong/expired code, rate-limited, or full
    case notHost
    case notMember
    case routeTooLarge
    case connectionFailed // transport reachability: the server was never reached (ROH-231)
}

/// A change in the backend's authenticated session, observed by `AuthStore`.
public enum AuthChange: Sendable, Equatable { case signedIn(UUID), signedOut }

/// The result of joining a ride: the ride record plus the host's route bytes,
/// so the guest can render the shared course without a second round trip.
///
/// `route` is optional because a destination-free ride has none (ROH-114). **Absent and
/// undecodable are different**: nil means "open ride, by design" and proceeds, while bytes
/// that fail to decode mean a corrupt payload and must not be silently reinterpreted as an
/// open ride. See `GroupRideSession.join(code:)`.
public struct JoinedRide: Sendable {
    public let ride: GroupRide
    public let route: Data?
    public init(ride: GroupRide, route: Data?) {
        self.ride = ride
        self.route = route
    }
}

/// A named roster entry for a group ride member.
public struct RosterMember: Equatable, Sendable {
    public let userID: UUID
    public let displayName: String
    public let role: RideMember.Role
    public init(userID: UUID, displayName: String, role: RideMember.Role) {
        self.userID = userID
        self.displayName = displayName
        self.role = role
    }
}

/// The Group Rides backend seam. The live conformer (Supabase) lives in the
/// app-target `AuraSync` module; tests inject `InMemoryGroupRideBackend`.
/// Methods are async and `nonisolated`-friendly: the conformer performs network
/// I/O off the main actor. Apple UI (ASAuthorization, the nonce dance) is the
/// app target's job; `signIn` receives an already-obtained identity token + nonce.
public protocol GroupRideBackend: Sendable {
    func signIn(idToken: String, nonce: String, displayName: String?) async throws
    func renameDisplayName(_ name: String) async throws
    func currentUserID() async throws -> UUID
    /// `route` is nil for a destination-free ride (ROH-114). Conformers must store that as a
    /// genuine absence — a SQL NULL, not a jsonb `'null'` — so `joinRide` can hand back nil
    /// rather than four bytes spelling `null`.
    func createRide(route: Data?) async throws -> GroupRide
    func joinRide(code: JoinCode) async throws -> JoinedRide
    func roster(rideID: UUID) async throws -> [RosterMember]
    func recordTrackPoints(rideID: UUID, points: [RemoteTrackPoint]) async throws
    /// Host-only: marks the ride as started (stamps `started_at`). Idempotent.
    func startRide(rideID: UUID) async throws
    /// The durable, authoritative lifecycle read (see `RideLifecycleStatus`).
    func rideStatus(rideID: UUID) async throws -> RideLifecycleStatus
    func endRide(rideID: UUID) async throws
    func leaveRide(rideID: UUID) async throws
    func deleteAccount() async throws

    /// Synchronous read of the current session's user id (Keychain-backed on the live
    /// conformer), for correct auth state on a cold launch without a network round trip.
    nonisolated var cachedUserID: UUID? { get }
    /// A stream of session changes for the store's lifetime.
    func authEvents() -> AsyncStream<AuthChange>
    /// Clears the authenticated session.
    func signOut() async throws
}
