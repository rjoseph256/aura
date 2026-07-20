import Testing
import Foundation
import AuraCore
@testable import AuraKit

@MainActor
struct WithTimeoutTests {
    @Test func operationWinsReturnsValue() async throws {
        // Instant operation beats the sleep → operation value returned. The sleep is bounded
        // (not an indefinite park) so the un-cancelled success-path timer reaps promptly.
        let value = try await withTimeout(.seconds(1), sleep: { _ in
            try await Task.sleep(for: .milliseconds(200))
        }, operation: { 42 })
        #expect(value == 42)
    }

    @Test func timeoutWinsThrowsTimeoutError() async {
        // Instant sleep, parked operation → TimeoutError.
        await #expect(throws: TimeoutError.self) {
            try await withTimeout(.seconds(1), sleep: { _ in }, operation: {
                try await Task.sleep(for: .seconds(1000))
            })
        }
    }

    struct SampleError: Error, Equatable {}

    @Test func operationErrorPropagates() async {
        // Operation throws first → its own error, not TimeoutError. The explicit `-> Int`
        // return type anchors the generic `T` (the throwing body gives it nothing to infer).
        await #expect(throws: SampleError.self) {
            try await withTimeout(.seconds(1), sleep: { _ in
                try await Task.sleep(for: .milliseconds(200))
            }, operation: { () async throws -> Int in throw SampleError() })
        }
    }
}

/// A one-shot async gate: `wait()` suspends until `open()` is called (once).
final class AsyncGate: @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    private let lock = NSLock()
    func wait() async {
        await withCheckedContinuation { c in
            lock.lock()
            if opened { lock.unlock(); c.resume(); return }
            continuation = c
            lock.unlock()
        }
    }
    func open() {
        lock.lock(); opened = true; let c = continuation; continuation = nil; lock.unlock()
        c?.resume()
    }
}

/// A switchable sleep seam. While `fireImmediately` is true it returns at once (the timeout
/// wins the race); when false it parks indefinitely (the operation wins). Lets one session —
/// whose `sleep` seam is fixed at init — time out on the first attempt and then succeed on a
/// retry (needed because `sleep: { _ in }` would otherwise beat even a would-succeed backend,
/// which must take an actor hop).
final class SleepControl: @unchecked Sendable {
    private let lock = NSLock()
    private var fire: Bool
    init(fireImmediately: Bool = true) { fire = fireImmediately }
    var fireImmediately: Bool {
        get { lock.lock(); defer { lock.unlock() }; return fire }
        set { lock.lock(); fire = newValue; lock.unlock() }
    }
    func sleep(_ duration: Duration) async throws {
        if fireImmediately { return }
        // Not firing: behave like a real timeout of `duration` (the fast operation beats it).
        // Bounded (not an indefinite park) so `withTimeout`'s un-cancelled success-path timer
        // no-ops and reaps quickly instead of lingering.
        try await Task.sleep(for: duration)
    }
}

@MainActor
struct GroupRideEndTimeoutTests {
    private func route() -> Route {
        Route(origin: .init(latitude: 0, longitude: 0), destination: .init(latitude: 1, longitude: 1),
              waypoints: [], geometry: [.init(latitude: 0, longitude: 0), .init(latitude: 1, longitude: 1)],
              profile: .fastest, distanceMeters: 100, estimatedDurationSeconds: 60, elevationGainMeters: 0)
    }

    /// A host session already advanced to `.riding`, with the given seams injected.
    private func ridingHost(
        endTimeout: Duration = .seconds(4),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
    ) async throws -> (GroupRideSession, InMemoryGroupRideBackend) {
        let backend = InMemoryGroupRideBackend()
        try await backend.signIn(idToken: "t", nonce: "n", displayName: "Mike")
        let s = GroupRideSession(backend: backend, transport: InMemoryRideSessionTransport(),
                                 displayNameProvider: { "Mike" }, endTimeout: endTimeout, sleep: sleep)
        await s.create(route: route())
        await s.startRiding()
        #expect(s.phase == .riding)
        return (s, backend)
    }

    @Test func hostEndTimeoutSetsEndFailedAndKeepsRiding() async throws {
        // Injected sleep is instant ({ _ in }); the parked backend loses the race → TimeoutError.
        let (s, backend) = try await ridingHost()
        backend.store.hangEndLeave = true
        await s.end()
        #expect(s.endFailed == true)
        #expect(s.phase == .riding)     // chrome kept
        #expect(s.isEnding == false)    // cleared at rest
    }

    @Test func hostEndTimeoutThenRetryReattempts() async throws {
        // First attempt times out (fireImmediately); retry succeeds once the seam stops firing
        // and the backend stops hanging — the operation then wins its actor-hop race.
        let ctrl = SleepControl(fireImmediately: true)
        let (s, backend) = try await ridingHost(sleep: { try await ctrl.sleep($0) })
        backend.store.hangEndLeave = true
        await s.end()
        #expect(s.endFailed == true)
        backend.store.hangEndLeave = false             // signal restored
        ctrl.fireImmediately = false                   // let the operation win the retry
        await s.retryEndIfNeeded()
        #expect(s.phase == .ended)                     // second attempt succeeds
        #expect(s.endFailed == false)                  // cleared on the successful finish
    }

    @Test func memberEndTimeoutSetsEndFailed() async throws {
        let (s, backend) = try await ridingHost()
        backend.store.hangEndLeave = true
        await s.endAsMember()
        #expect(s.endFailed == true)
        #expect(s.isEnding == false)
    }

    @Test func memberLeaveTimeoutShowsNoFeedback() async throws {
        // The Critical-fix lock: keep-riding leave never surfaces a chip/pending state.
        let (s, backend) = try await ridingHost()
        backend.store.hangEndLeave = true
        await s.leave()
        #expect(s.endFailed == false)
        #expect(s.isEnding == false)
        #expect(s.phase == .riding)     // still riding; no yank affordance
    }

    @Test func isEndingIsTrueWhileInFlight() async throws {
        // Non-instant sleep so the timeout doesn't fire; entry signal proves isEnding was set.
        let entered = AsyncGate()
        let (s, backend) = try await ridingHost(
            sleep: { _ in try await Task.sleep(for: .seconds(1000)) })
        backend.store.hangEndLeave = true
        backend.store.onEndLeaveEntered = { entered.open() }
        let task = Task { await s.end() }
        await entered.wait()            // deterministic: endRide entered → isEnding already set
        #expect(s.isEnding == true)
        task.cancel()
    }

    @Test func doubleEndInvokesBackendOnce() async throws {
        // Re-entrancy guard: a second waited-on end while one is in flight is a no-op.
        let entered = AsyncGate()
        let (s, backend) = try await ridingHost(
            sleep: { _ in try await Task.sleep(for: .seconds(1000)) })
        backend.store.hangEndLeave = true
        backend.store.onEndLeaveEntered = { entered.open() }
        let first = Task { await s.end() }
        await entered.wait()
        await s.end()                   // re-entrant call — guarded out
        #expect(backend.store.endLeaveCallCount == 1)
        first.cancel()
    }

    @Test func wireEndedAfterTimeoutClearsPendingLatch() async throws {
        // 1) End times out → endFailed = true, pendingEnd = true, endLeaveCallCount == 1.
        let (s, backend) = try await ridingHost()   // default instant sleep → timeout wins
        backend.store.hangEndLeave = true
        await s.end()
        #expect(s.endFailed == true)
        #expect(backend.store.endLeaveCallCount == 1)
        // 2) A wire .rideEnded dissolves the ride (host is this session; the guest-toast branch is
        //    skipped, but phase = .ended + teardownLive still run).
        backend.store.hangEndLeave = false
        await s.ingest(.rideEnded)
        #expect(s.phase == .ended)
        // 3) teardownLive must have cleared the latches: no stale chip, and retry is a no-op.
        #expect(s.endFailed == false)               // fails without the teardownLive reset
        #expect(s.isEnding == false)
        await s.retryEndIfNeeded()
        #expect(backend.store.endLeaveCallCount == 1) // fails (== 2) without the pendingEnd reset
    }
}
