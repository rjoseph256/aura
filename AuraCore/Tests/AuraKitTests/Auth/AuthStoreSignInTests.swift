import Testing
import Foundation
@testable import AuraKit

@MainActor struct AuthStoreSignInTests {
    struct FakeApple: AppleAuthenticating {
        let r: Result<AppleCredential, AppleAuthError>
        func signIn() async throws -> AppleCredential { try r.get() }
    }
    private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "auth.signin.\(UUID())")! }

    @Test func signsInAndSeedsCrewNameFromApple() async {
        let b = InMemoryGroupRideBackend(); let d = freshDefaults()
        let s = AuthStore(backend: b, apple: FakeApple(r: .success(.init(idToken: "t", rawNonce: "n", fullName: "Rohun"))), defaults: d)
        await s.signInWithApple()
        #expect(s.isSignedIn == true)
        #expect(s.status == .idle)
        #expect(d.string(forKey: DisplayNameStore.crewDisplayNameKey) == "Rohun")
    }

    @Test func noNameFromAppleLeavesCrewNameForTheGate() async {
        let b = InMemoryGroupRideBackend(); let d = freshDefaults()
        let s = AuthStore(backend: b, apple: FakeApple(r: .success(.init(idToken: "t", rawNonce: "n", fullName: nil))), defaults: d)
        await s.signInWithApple()
        #expect(s.isSignedIn == true)
        #expect(d.string(forKey: DisplayNameStore.crewDisplayNameKey) == nil)
    }

    @Test func cancelIsSilent() async {
        let b = InMemoryGroupRideBackend(); let d = freshDefaults()
        let s = AuthStore(backend: b, apple: FakeApple(r: .failure(.canceled)), defaults: d)
        await s.signInWithApple()
        #expect(s.isSignedIn == false)
        #expect(s.status == .idle)
    }

    @Test func failureSetsError() async {
        let b = InMemoryGroupRideBackend(); let d = freshDefaults()
        let s = AuthStore(backend: b, apple: FakeApple(r: .failure(.failed)), defaults: d)
        await s.signInWithApple()
        #expect(s.isSignedIn == false)
        if case .error = s.status {} else { Issue.record("expected .error, got \(s.status)") }
    }

    @Test func differentUserClearsStaleCrewName() async {
        let b = InMemoryGroupRideBackend(); let d = freshDefaults()
        d.set("Alice", forKey: DisplayNameStore.crewDisplayNameKey)          // leftover from a prior user
        d.set(UUID().uuidString, forKey: AuthStore.lastUserIDKey)            // a DIFFERENT prior user
        let s = AuthStore(backend: b, apple: FakeApple(r: .success(.init(idToken: "t", rawNonce: "n", fullName: nil))), defaults: d)
        await s.signInWithApple()
        #expect(d.string(forKey: DisplayNameStore.crewDisplayNameKey) == nil) // stale name cleared
    }
}
