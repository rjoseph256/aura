import Foundation
import AuraCore

public enum GroupRideError: Error, Equatable, Sendable {
    case notAuthenticated
    case joinFailed       // generic: wrong/expired code, rate-limited, or full
    case notHost
    case notMember
    case routeTooLarge
}

/// The result of joining a ride: the ride record plus the host's route bytes,
/// so the guest can render the shared course without a second round trip.
public struct JoinedRide: Sendable {
    public let ride: GroupRide
    public let route: Data
    public init(ride: GroupRide, route: Data) {
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
    func currentUserID() async throws -> UUID
    func createRide(route: Data) async throws -> GroupRide
    func joinRide(code: JoinCode) async throws -> JoinedRide
    func roster(rideID: UUID) async throws -> [RosterMember]
    func recordTrackPoints(rideID: UUID, points: [RemoteTrackPoint]) async throws
    func endRide(rideID: UUID) async throws
    func leaveRide(rideID: UUID) async throws
    func deleteAccount() async throws
}
