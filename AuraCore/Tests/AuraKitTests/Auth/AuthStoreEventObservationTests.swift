import Testing
import Foundation
@testable import AuraKit

/// AuthStore's cold-launch read is covered elsewhere; this pins the *live* half — the
/// event task started in `init` that keeps `userID` in sync with the backend's
/// `authEvents()` stream, independent of the `signInWithApple`/`signOut` paths (which
/// also set `userID` directly). Drives the backend's session seam straight and asserts
/// the store follows.
@MainActor struct AuthStoreEventObservationTests {
    private struct FakeApple: AppleAuthenticating {
        func signIn() async throws -> AppleCredential { .init(idToken: "t", rawNonce: "n", fullName: nil) }
    }

    /// Yields the main actor until `cond` holds (or a generous cap), so the test never
    /// races the event task's async subscribe/deliver without resorting to fixed sleeps.
    private func waitUntil(_ cond: @MainActor () -> Bool) async {
        for _ in 0..<1000 {
            if cond() { return }
            await Task.yield()
        }
    }

    @Test func tracksBackendSignInAndSignOutLive() async throws {
        let b = InMemoryGroupRideBackend()
        let d = UserDefaults(suiteName: "auth.evt.\(UUID())")!
        let s = AuthStore(backend: b, apple: FakeApple(), defaults: d)
        #expect(s.isSignedIn == false)

        // Wait until the event task has subscribed, so the emit below can't be dropped.
        await waitUntil { b.store.lock.withLock { !b.store.authContinuations.isEmpty } }

        // A backend-side sign-in — NOT via signInWithApple — must flow through authEvents.
        try await b.signIn(idToken: "t", nonce: "n", displayName: nil)
        await waitUntil { s.userID != nil }
        #expect(s.userID == b.cachedUserID)

        // And a backend-side sign-out must clear it back to signed-out.
        try await b.signOut()
        await waitUntil { s.userID == nil }
        #expect(s.isSignedIn == false)
    }
}
