import Foundation
import AuraCore

public final actor InMemoryGroupRideBackend: GroupRideBackend {
    final class Store: @unchecked Sendable {
        var rides: [UUID: GroupRide] = [:]
        var members: [UUID: [UUID]] = [:]   // rideID -> [userID]
        var codes: [String: UUID] = [:]     // joinCode -> rideID
        var routes: [UUID: Data] = [:]       // rideID -> route bytes; absent = open ride
        var names: [UUID: String] = [:]      // userID -> display name
        var leaveCalled = false              // test spy
        var forceCreateError: GroupRideError?    // test spy
        var forceRenameError: GroupRideError?    // test spy
        var forceDeleteError: GroupRideError?    // test spy
        var forceStartError: GroupRideError?     // test spy
        var forceRosterError: GroupRideError?    // test spy
        var forceEndError: GroupRideError?       // test spy, one-shot: cleared on throw so a retry succeeds
        var hangEndLeave = false                          // test spy: park endRide/leaveRide until cancelled
        var onEndLeaveEntered: (@Sendable () -> Void)?    // test spy: fired when end/leave is entered
        var endLeaveCallCount = 0                          // test spy: how many times end/leave ran
        var rosterCallCount = 0   // test spy: how many times roster() ran
        var joinCallCount = 0   // test spy: how many times joinRide ran

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
    public func createRide(route: Data?) async throws -> GroupRide {
        guard let uid = store.lock.withLock({ store.currentUserID }) else { throw GroupRideError.notAuthenticated }
        if let forced = store.forceCreateError { throw forced }
        let code = JoinCode(rawValue: "ABCDEFGH")!   // fixed valid code for the fake (one ride per store)
        // `kind` is derived here, from the absence of route bytes, exactly as `create_ride` derives
        // it in SQL (`0021_open_rides.sql`). A fake that stamped a fixed `.route` instead would
        // report every ride as a route ride — including the route-less ones this whole feature is
        // about — and the lifecycle rebuilds below would then faithfully carry the wrong answer.
        let ride = GroupRide(id: UUID(), hostID: uid, joinCode: code,
                             kind: route == nil ? .open : .route,
                             status: .active, createdAt: Date(timeIntervalSince1970: 0))
        store.rides[ride.id] = ride
        store.members[ride.id] = [uid]
        store.codes[code.rawValue] = ride.id
        store.routes[ride.id] = route
        return ride
    }
    public func joinRide(code: JoinCode) async throws -> JoinedRide {
        store.joinCallCount += 1
        guard let uid = store.lock.withLock({ store.currentUserID }) else { throw GroupRideError.notAuthenticated }
        guard let rideID = store.codes[code.rawValue],
              let ride = store.rides[rideID] else { throw GroupRideError.joinFailed }
        var members = store.members[rideID] ?? []
        if members.contains(uid) {
            return JoinedRide(ride: ride, route: store.routes[rideID])
        }       // idempotent
        guard members.count < 8 else { throw GroupRideError.joinFailed }
        members.append(uid)
        store.members[rideID] = members
        return JoinedRide(ride: ride, route: store.routes[rideID])
    }
    public func roster(rideID: UUID) async throws -> [RosterMember] {
        store.rosterCallCount += 1
        if let forced = store.forceRosterError { throw forced }
        return (store.members[rideID] ?? []).map {
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
        store.rides[rideID] = ride.replacing(startedAt: Date(timeIntervalSince1970: 10))
    }

    public func rideStatus(rideID: UUID) async throws -> RideLifecycleStatus {
        guard let ride = store.rides[rideID] else { throw GroupRideError.joinFailed }
        return RideLifecycleStatus(hostID: ride.hostID, startedAt: ride.startedAt, endedAt: ride.endedAt)
    }

    public func endRide(rideID: UUID) async throws {
        store.endLeaveCallCount += 1
        store.onEndLeaveEntered?()
        if store.hangEndLeave { try await Task.sleep(for: .seconds(1000)) }
        if let forced = store.forceEndError { store.forceEndError = nil; throw forced }
        guard let uid = store.lock.withLock({ store.currentUserID }), let ride = store.rides[rideID], ride.hostID == uid
        else { throw GroupRideError.notHost }
        store.rides[rideID] = ride.replacing(status: .ended, endedAt: Date(timeIntervalSince1970: 20))
    }
    public func leaveRide(rideID: UUID) async throws {
        store.endLeaveCallCount += 1
        store.onEndLeaveEntered?()
        if store.hangEndLeave { try await Task.sleep(for: .seconds(1000)) }
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
