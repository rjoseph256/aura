import Foundation
import AuraCore

public final actor InMemoryGroupRideBackend: GroupRideBackend {
    final class Store: @unchecked Sendable {
        var rides: [UUID: GroupRide] = [:]
        var members: [UUID: [UUID]] = [:]   // rideID -> [userID]
        var codes: [String: UUID] = [:]     // joinCode -> rideID
    }
    // nonisolated so `init(sharing:)` can read it synchronously across actors;
    // `Store` is @unchecked Sendable, and tests drive it via serial awaits.
    nonisolated let store: Store
    private var currentUser: UUID?

    public init() { self.store = Store() }
    public init(sharing other: InMemoryGroupRideBackend) { self.store = other.store }

    public func signIn(idToken: String, nonce: String, displayName: String?) async throws {
        currentUser = UUID()
    }
    public func createRide(route: Data) async throws -> GroupRide {
        guard let uid = currentUser else { throw GroupRideError.notAuthenticated }
        let code = JoinCode(rawValue: "ABCDEFGH")!   // fixed valid code for the fake (one ride per store)
        let ride = GroupRide(id: UUID(), hostID: uid, joinCode: code,
                             status: .active, createdAt: Date(timeIntervalSince1970: 0))
        store.rides[ride.id] = ride
        store.members[ride.id] = [uid]
        store.codes[code.rawValue] = ride.id
        return ride
    }
    public func joinRide(code: JoinCode) async throws -> GroupRide {
        guard let uid = currentUser else { throw GroupRideError.notAuthenticated }
        guard let rideID = store.codes[code.rawValue],
              let ride = store.rides[rideID] else { throw GroupRideError.joinFailed }
        var members = store.members[rideID] ?? []
        if members.contains(uid) { return ride }       // idempotent
        guard members.count < 8 else { throw GroupRideError.joinFailed }
        members.append(uid)
        store.members[rideID] = members
        return ride
    }
    public func recordTrackPoints(rideID: UUID, points: [RemoteTrackPoint]) async throws {
        guard let uid = currentUser, store.members[rideID]?.contains(uid) == true
        else { throw GroupRideError.notMember }
    }
    public func endRide(rideID: UUID) async throws {
        guard let uid = currentUser, store.rides[rideID]?.hostID == uid
        else { throw GroupRideError.notHost }
    }
    public func leaveRide(rideID: UUID) async throws {
        guard let uid = currentUser else { throw GroupRideError.notAuthenticated }
        store.members[rideID]?.removeAll { $0 == uid }
    }
    public func deleteAccount() async throws { currentUser = nil }
}
