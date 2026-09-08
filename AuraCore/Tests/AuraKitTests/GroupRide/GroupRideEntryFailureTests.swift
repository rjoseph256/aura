import Testing
import Foundation
import AuraCore
@testable import AuraKit

@MainActor
struct GroupRideEntryFailureTests {
    func makeSession(backend: InMemoryGroupRideBackend,
                     sleep: (@Sendable (Duration) async throws -> Void)? = nil) -> GroupRideSession {
        GroupRideSession(backend: backend, transport: InMemoryRideSessionTransport(),
                         displayNameProvider: { "Jamie" }, sleep: sleep)
    }

    func makeBackend() async -> InMemoryGroupRideBackend {
        let backend = InMemoryGroupRideBackend()
        try? await backend.signIn(idToken: "t", nonce: "n", displayName: "Jamie")
        return backend
    }

    @Test func anUnknownCodeIsARejection() async {
        let session = makeSession(backend: await makeBackend())
        await session.join(code: JoinCode(rawValue: "AAAA2222")!)
        #expect(session.phase == .joinFailed)
        #expect(session.entryFailureReason == .rejected)
    }

    @Test func aTransportFailureIsAConnectionFailure() async {
        let backend = await makeBackend()
        backend.store.forceJoinError = .connectionFailed
        let session = makeSession(backend: backend)
        await session.join(code: JoinCode(rawValue: "AAAA2222")!)
        #expect(session.phase == .joinFailed)
        #expect(session.entryFailureReason == .connectionFailed)
    }

    @Test func aHungJoinResolvesToAConnectionFailureNotAnEternalSpinner() async {
        let backend = await makeBackend()
        backend.store.hangJoin = true
        let session = makeSession(backend: backend, sleep: { _ in })   // instant entry timeout
        await session.join(code: JoinCode(rawValue: "AAAA2222")!)
        #expect(session.phase == .joinFailed)
        #expect(session.entryFailureReason == .connectionFailed)
    }

    @Test func aHungCreateResolvesToAConnectionFailure() async {
        let backend = await makeBackend()
        backend.store.hangCreate = true
        let session = makeSession(backend: backend, sleep: { _ in })
        await session.create(route: nil)
        #expect(session.phase == .createFailed)
        #expect(session.entryFailureReason == .connectionFailed)
    }

    @Test func aRetryClearsTheReasonAndSucceeds() async {
        let session = makeSession(backend: await makeBackend())
        await session.join(code: JoinCode(rawValue: "AAAA2222")!)   // fails: no such ride
        #expect(session.entryFailureReason == .rejected)
        await session.create(route: nil)                            // fresh attempt succeeds
        #expect(session.entryFailureReason == nil, "cleared at the top of the attempt")
        #expect(session.phase == .lobby)
    }

    /// The retry surface shows loading again because the attempt resets phase to `.idle` —
    /// observable mid-flight against a parked backend (gate finding: v1 asserted this nowhere).
    @Test func aRetryReEntersTheLoadingPhaseWhileInFlight() async {
        let backend = await makeBackend()
        let session = makeSession(backend: backend)
        await session.join(code: JoinCode(rawValue: "AAAA2222")!)
        #expect(session.phase == .joinFailed)
        backend.store.hangJoin = true
        let attempt = Task { await session.join(code: JoinCode(rawValue: "AAAA2222")!) }
        for _ in 0..<500 where session.phase != .idle { await Task.yield() }
        #expect(session.phase == .idle, "the second attempt re-entered loading")
        attempt.cancel()
        _ = await attempt.value
    }

    /// Two taps on Try-again must not create two rides (gate finding: create/join had no
    /// re-entrancy guard where finishRide has isEnding).
    @Test func concurrentJoinAttemptsCollapseToOne() async {
        let backend = await makeBackend()
        backend.store.hangJoin = true
        let session = makeSession(backend: backend)
        let first = Task { await session.join(code: JoinCode(rawValue: "AAAA2222")!) }
        for _ in 0..<500 where backend.store.joinCallCount == 0 { await Task.yield() }
        await session.join(code: JoinCode(rawValue: "AAAA2222")!)   // second tap: rejected by the latch
        #expect(backend.store.joinCallCount == 1, "one server-side attempt")
        first.cancel()
        _ = await first.value
    }
}
