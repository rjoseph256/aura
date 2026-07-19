import Foundation
import AuraCore

public final actor InMemoryGroupRideBackend: GroupRideBackend {
    final class Store: @unchecked Sendable {
        var rides: [UUID: GroupRide] = [:]
        var members: [UUID: [UUID]] = [:]   // rideID -> [userID]
        var codes: [String: UUID] = [:]     // joinCode -> rideID
        var routes: [UUID: Data] = [:]       // rideID -> route bytes
        var names: [UUID: String] = [:]      // userID -> display name
        var leaveCalled = false              // test spy
        var forceCreateError: GroupRideError?    // test spy
        var forceRenameError: GroupRideError?    // test spy
        var forceDeleteError: GroupRideError?    // test spy
        var forceStartError: GroupRideError?     // test spy

        // Auth-state seam (added Task 2). The signed-in id and its observers live
        // here (not on the actor) so `cachedUserID` can be `nonisolated` while
        // still reflecting the actor-mutated session synchronously.
        let lock = NSLock()
        var currentUserID: UUID?
        var authContinuations: [UUID: AsyncStream<AuthChange>.Continuation] = [:]
    }
    // nonisolated so `init(sharing:)` can read it synchronously across actors;
    // `Store` is @unchecked Sendable, and tests drive it via serial awaits.
    nonisolated let store: Store

    public init() { self.store = Store() }
    public init(sharing other: InMemoryGroupRideBackend) { self.store = other.store }

    public func signIn(idToken: String, nonce: String, displayName: String?) async throws {
        let uid = UUID()
        store.lock.withLock { store.currentUserID = uid }
        store.names[uid] = DisplayName.forDisplay(displayName ?? "")
        emit(.signedIn(uid))
    }
    public func renameDisplayName(_ name: String) async throws {
        guard let uid = store.lock.withLock({ store.currentUserID }) else { throw GroupRideError.notAuthenticated }
        if let forced = store.forceRenameError { throw forced }
        store.names[uid] = name
    }
    public func currentUserID() async throws -> UUID {
        guard let uid = store.lock.withLock({ store.currentUserID }) else { throw GroupRideError.notAuthenticated }
        return uid
    }
    public func createRide(route: Data) async throws -> GroupRide {
        guard let uid = store.lock.withLock({ store.currentUserID }) else { throw GroupRideError.notAuthenticated }
        if let forced = store.forceCreateError { throw forced }
        let code = JoinCode(rawValue: "ABCDEFGH")!   // fixed valid code for the fake (one ride per store)
        let ride = GroupRide(id: UUID(), hostID: uid, joinCode: code,
                             status: .active, createdAt: Date(timeIntervalSince1970: 0))
        store.rides[ride.id] = ride
        store.members[ride.id] = [uid]
        store.codes[code.rawValue] = ride.id
        store.routes[ride.id] = route
        return ride
    }
    public func joinRide(code: JoinCode) async throws -> JoinedRide {
        guard let uid = store.lock.withLock({ store.currentUserID }) else { throw GroupRideError.notAuthenticated }
        guard let rideID = store.codes[code.rawValue],
              let ride = store.rides[rideID] else { throw GroupRideError.joinFailed }
        var members = store.members[rideID] ?? []
        if members.contains(uid) {
            return JoinedRide(ride: ride, route: store.routes[rideID] ?? Data())
        }       // idempotent
        guard members.count < 8 else { throw GroupRideError.joinFailed }
        members.append(uid)
        store.members[rideID] = members
        return JoinedRide(ride: ride, route: store.routes[rideID] ?? Data())
    }
    public func roster(rideID: UUID) async throws -> [RosterMember] {
        (store.members[rideID] ?? []).map {
            RosterMember(userID: $0, displayName: store.names[$0] ?? "Rider",
                         role: $0 == store.rides[rideID]?.hostID ? .host : .member)
        }
    }
    public func recordTrackPoints(rideID: UUID, points: [RemoteTrackPoint]) async throws {
        guard let uid = store.lock.withLock({ store.currentUserID }), store.members[rideID]?.contains(uid) == true
        else { throw GroupRideError.notMember }
    }
    public func startRide(rideID: UUID) async throws {
        if let forced = store.forceStartError { throw forced }
        guard let uid = store.lock.withLock({ store.currentUserID }) else { throw GroupRideError.notAuthenticated }
        guard let ride = store.rides[rideID], ride.hostID == uid else { throw GroupRideError.notHost }
        guard ride.startedAt == nil, ride.endedAt == nil else { return }   // idempotent
        store.rides[rideID] = GroupRide(id: ride.id, hostID: ride.hostID, joinCode: ride.joinCode,
                                        status: ride.status, createdAt: ride.createdAt,
                                        startedAt: Date(timeIntervalSince1970: 10), endedAt: ride.endedAt)
    }

    public func rideStatus(rideID: UUID) async throws -> RideLifecycleStatus {
        guard let ride = store.rides[rideID] else { throw GroupRideError.joinFailed }
        return RideLifecycleStatus(hostID: ride.hostID, startedAt: ride.startedAt, endedAt: ride.endedAt)
    }

    public func endRide(rideID: UUID) async throws {
        guard let uid = store.lock.withLock({ store.currentUserID }), let ride = store.rides[rideID], ride.hostID == uid
        else { throw GroupRideError.notHost }
        store.rides[rideID] = GroupRide(id: ride.id, hostID: ride.hostID, joinCode: ride.joinCode,
                                        status: .ended, createdAt: ride.createdAt,
                                        startedAt: ride.startedAt, endedAt: Date(timeIntervalSince1970: 20))
    }
    public func leaveRide(rideID: UUID) async throws {
        guard let uid = store.lock.withLock({ store.currentUserID }) else { throw GroupRideError.notAuthenticated }
        store.members[rideID]?.removeAll { $0 == uid }
        store.leaveCalled = true
    }
    public func deleteAccount() async throws {
        if let forced = store.forceDeleteError { throw forced }
        store.lock.withLock { store.currentUserID = nil }
    }

    // MARK: - Auth-state seam (added Task 2)

    public nonisolated var cachedUserID: UUID? { store.lock.withLock { store.currentUserID } }

    public nonisolated func authEvents() -> AsyncStream<AuthChange> {
        AsyncStream { continuation in
            let key = UUID()
            store.lock.withLock { store.authContinuations[key] = continuation }
            continuation.onTermination = { [store] _ in
                store.lock.withLock { store.authContinuations[key] = nil }
            }
        }
    }

    public func signOut() async throws {
        store.lock.withLock { store.currentUserID = nil }
        emit(.signedOut)
    }

    private nonisolated func emit(_ change: AuthChange) {
        let continuations = store.lock.withLock { Array(store.authContinuations.values) }
        for continuation in continuations { continuation.yield(change) }
    }
}
