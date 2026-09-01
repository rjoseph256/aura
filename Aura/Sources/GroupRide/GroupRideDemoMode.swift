import Foundation
import AuraCore
import AuraKit

#if DEBUG
/// Launch-argument-gated demo wiring so the group surfaces can be driven on a simulator
/// that cannot Sign in with Apple (Tier-1 evidence, ROH-225). Active ONLY when the app is
/// launched with `-auraDemoGroupRides`; release builds compile none of this.
///
///   xcrun simctl launch <udid> com.rohunjoseph.aura -auraDemoGroupRides [option]
///
/// Options (at most one):
///   -auraDemoJoinRejected    joinRide throws .joinFailed   (rejected surface)
///   -auraDemoJoinConnection  joinRide throws .connectionFailed (connection surface)
///   -auraDemoJoinHang        joinRide parks ~1000s → entry timeout (loading → connection)
///   -auraDemoCreateHang      createRide parks the same way (create loading → connection)
///   -auraDemoCrew            after create, three riders join in-process a beat apart, so
///                            the lobby poll (ROH-227) fills the room live on the sim
@MainActor
enum GroupRideDemoMode {
    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains("-auraDemoGroupRides")
    }

    /// One shared backend per process so the flow, the name store, and the demo crew all
    /// see the same in-memory store (the GroupLobbyView-preview idiom, app-side).
    ///
    /// Spy flags are set SYNCHRONOUSLY, before the `Task` below is spawned: `store` is a
    /// plain `nonisolated` class (`InMemoryGroupRideBackend.Store`), so writing its flags
    /// here happens-before `backend` is returned from this initializer, and therefore
    /// happens-before `GroupRideFlowView`'s `.task { await invokeEntry() }` can possibly
    /// read them. Only `signIn` — genuinely async — stays inside the `Task`. Putting the
    /// flag-writes inside that same `Task` (as the brief first sketched) would race the
    /// flow's own first `create`/`join` call: on a slow scheduler the flow could reach
    /// `createRide`/`joinRide` before the spy flags were ever written, silently skipping
    /// the forced failure/hang the launch argument asked for.
    static let backend: InMemoryGroupRideBackend = {
        let backend = InMemoryGroupRideBackend()
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-auraDemoJoinRejected") { backend.store.forceJoinError = .joinFailed }
        if args.contains("-auraDemoJoinConnection") { backend.store.forceJoinError = .connectionFailed }
        if args.contains("-auraDemoJoinHang") { backend.store.hangJoin = true }
        if args.contains("-auraDemoCreateHang") { backend.store.hangCreate = true }
        Task {
            try? await backend.signIn(idToken: "demo-host", nonce: "demo", displayName: "Jamie")
        }
        return backend
    }()

    /// Joins three riders through the real joinRide path, one per beat, so the lobby fills
    /// through the actual roster poll rather than a seeded fixture.
    static func startDemoCrewIfRequested(code: JoinCode) {
        guard ProcessInfo.processInfo.arguments.contains("-auraDemoCrew") else { return }
        Task {
            for (index, name) in ["Mara", "Priya", "Devon"].enumerated() {
                try? await Task.sleep(for: .seconds(2 + index * 3))
                let guest = InMemoryGroupRideBackend(sharing: backend)
                try? await guest.signIn(idToken: "demo-\(name)", nonce: "demo", displayName: name)
                _ = try? await guest.joinRide(code: code)
            }
        }
    }
}
#endif
