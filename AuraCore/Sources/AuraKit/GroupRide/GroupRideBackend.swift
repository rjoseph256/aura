import Foundation
import AuraCore

public enum GroupRideError: Error, Equatable, Sendable {
    case notAuthenticated
    case joinFailed       // generic: wrong/expired code, rate-limited, or full
    case notHost
    case notMember
}

/// The Group Rides backend seam. The live conformer (Supabase) lives in the
/// app-target `AuraSync` module; tests inject `InMemoryGroupRideBackend`.
/// Methods are async and `nonisolated`-friendly: the conformer performs network
/// I/O off the main actor. Apple UI (ASAuthorization, the nonce dance) is the
/// app target's job; `signIn` receives an already-obtained identity token + nonce.
public protocol GroupRideBackend: Sendable {
    func signIn(idToken: String, nonce: String, displayName: String?) async throws
    func createRide(route: Data) async throws -> GroupRide
    func joinRide(code: JoinCode) async throws -> GroupRide
    func recordTrackPoints(rideID: UUID, points: [RemoteTrackPoint]) async throws
    func endRide(rideID: UUID) async throws
    func leaveRide(rideID: UUID) async throws
    func deleteAccount() async throws
}
