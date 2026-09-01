import Testing
import Foundation
import AuraCore
@testable import AuraKit

/// Releases the session's injected `pollSleep` one interval at a time, so the poll cadence
/// is test-driven rather than wall-clock. LEVEL-TRIGGERED: a release with nobody parked is
/// banked as a permit, so a release racing task startup is never lost (gate finding — the
/// edge-triggered version lost the wakeup 200/200 when release beat the task's first park).
/// Cancellation-aware: a cancelled sleeper resumes immediately so `teardownLive` can unwind.
actor SleepGate {
    private var permits = 0
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextID = 0

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled || permits > 0 {
                    if permits > 0 { permits -= 1 }
                    continuation.resume()
                } else {
                    nextID += 1
                    waiters[nextID] = continuation
                }
            }
        } onCancel: {
            Task { await self.drain() }
        }
    }

    func release() {
        if let first = waiters.keys.sorted().first, let continuation = waiters.removeValue(forKey: first) {
            continuation.resume()
        } else {
            permits += 1
        }
    }

    private func drain() {
        let parked = waiters
        waiters = [:]
        for continuation in parked.values { continuation.resume() }
    }
}

@MainActor
struct GroupRideLobbyPollTests {
    /// Bounded, condition-driven settle (ROH-217 precedent) — never a wall-clock sleep.
    func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    func makeHost(gate: SleepGate) async -> (GroupRideSession, InMemoryGroupRideBackend) {
        let backend = InMemoryGroupRideBackend()
        try? await backend.signIn(idToken: "host", nonce: "n", displayName: "Jamie")
        let session = GroupRideSession(
            backend: backend, transport: InMemoryRideSessionTransport(),
            displayNameProvider: { "Jamie" },
            pollSleep: { _ in await gate.wait() })
        await session.create(route: nil)
        return (session, backend)
    }

    @discardableResult
    func joinGuest(named name: String, sharing backend: InMemoryGroupRideBackend,
                   code: JoinCode) async throws -> InMemoryGroupRideBackend {
        let guest = InMemoryGroupRideBackend(sharing: backend)
        try await guest.signIn(idToken: "guest-\(name)", nonce: "n", displayName: name)
        _ = try await guest.joinRide(code: code)
        return guest
    }

    @Test func aJoinerAppearsAfterOnePollIntervalWithNoPosition() async throws {
        let gate = SleepGate()
        let (session, backend) = await makeHost(gate: gate)
        await session.beginLiveSession()
        try await joinGuest(named: "Priya", sharing: backend, code: session.joinCode!)
        #expect(session.peers.count == 1, "not yet — no interval has elapsed")
        await gate.release()
        await settle { session.peers.count == 2 }
        #expect(session.peers.count == 2)
        #expect(session.peers.contains { $0.status == .awaiting && session.nameMap[$0.userID] == "Priya" })
    }

    @Test func thePollIsIdempotentWithTheSeedRoster() async throws {
        let gate = SleepGate()
        let (session, backend) = await makeHost(gate: gate)
        try await joinGuest(named: "Priya", sharing: backend, code: session.joinCode!)
        await session.beginLiveSession()          // seed already contains Priya
        let seeded = session.peers.count
        let calls = backend.store.rosterCallCount
        await gate.release()
        // POSITIVE CONTROL first (gate finding: without it this test passes vacuously
        // whenever the poll simply never ran).
        await settle { backend.store.rosterCallCount > calls }
        #expect(backend.store.rosterCallCount > calls, "the poll actually re-fetched")
        #expect(session.peers.count == seeded, "re-polling the same roster adds nothing")
    }

    @Test func thePollStopsWhenTheRideEnds() async throws {
        let gate = SleepGate()
        let (session, backend) = await makeHost(gate: gate)
        await session.beginLiveSession()
        await session.end()                       // teardownLive cancels the poll
        await settle { session.phase == .ended }
        let calls = backend.store.rosterCallCount
        await gate.release()                      // banked or wakes a straggler — guard must hold
        await settle { false }
        #expect(backend.store.rosterCallCount == calls, "no roster fetch after teardown")
    }

    /// The gate's headline A0 finding: an optimistic `.rideStarted` followed by an
    /// authoritative reconcile back to `.lobby` (the phantom-start correction that
    /// `GroupRideSessionLifecycleSyncTests` already exercises) must NOT kill the poll —
    /// v1 coupled the poll to `beginLiveSession`'s one-shot latch and died here silently.
    @Test func thePollSurvivesAPhantomStartRoundTrip() async throws {
        let gate = SleepGate()
        let (session, backend) = await makeHost(gate: gate)
        await session.beginLiveSession()
        await session.ingest(.rideStarted)
        #expect(session.phase == .riding)
        await session.reconcileFromStatus()       // server never stamped started_at
        #expect(session.phase == .lobby)
        try await joinGuest(named: "Priya", sharing: backend, code: session.joinCode!)
        await gate.release()
        await settle { session.peers.count == 2 }
        #expect(session.peers.count == 2, "the poll is alive after the round trip")
    }
}
