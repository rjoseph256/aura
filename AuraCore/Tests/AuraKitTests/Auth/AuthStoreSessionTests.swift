import Testing
import Foundation
@testable import AuraKit

@MainActor struct AuthStoreSessionTests {
    struct FakeApple: AppleAuthenticating {
        func signIn() async throws -> AppleCredential { .init(idToken: "t", rawNonce: "n", fullName: "Rohun") }
    }
    @Test func signOutClearsSessionKeepsCrewName() async {
        let b = InMemoryGroupRideBackend(); let d = UserDefaults(suiteName: "auth.so.\(UUID())")!
        let s = AuthStore(backend: b, apple: FakeApple(), defaults: d)
        await s.signInWithApple()
        #expect(s.isSignedIn == true)
        await s.signOut()
        #expect(s.isSignedIn == false)
        #expect(d.string(forKey: DisplayNameStore.crewDisplayNameKey) == "Rohun")  // kept for same-user re-sign-in
    }
    @Test func deleteAccountClearsSessionAndCrewName() async {
        let b = InMemoryGroupRideBackend(); let d = UserDefaults(suiteName: "auth.da.\(UUID())")!
        let s = AuthStore(backend: b, apple: FakeApple(), defaults: d)
        await s.signInWithApple()
        await s.deleteAccount()
        #expect(s.isSignedIn == false)
        #expect(d.string(forKey: DisplayNameStore.crewDisplayNameKey) == nil)
        #expect(d.string(forKey: AuthStore.lastUserIDKey) == nil)
    }

    @Test func deleteAccountFailureKeepsSessionAndSurfacesError() async {
        let b = InMemoryGroupRideBackend(); let d = UserDefaults(suiteName: "auth.daf.\(UUID())")!
        let s = AuthStore(backend: b, apple: FakeApple(), defaults: d)
        await s.signInWithApple()
        #expect(s.isSignedIn == true)

        b.store.forceDeleteError = .notAuthenticated   // the delete edge fn / RPC rejects
        await s.deleteAccount()

        // A failed delete must not sign the rider out or wipe their local name: the catch
        // path only surfaces an error, so a retry still has a live session to delete.
        if case .error = s.status {} else { Issue.record("expected .error, got \(s.status)") }
        #expect(s.isSignedIn == true)
        #expect(d.string(forKey: DisplayNameStore.crewDisplayNameKey) == "Rohun")
        #expect(d.string(forKey: AuthStore.lastUserIDKey) != nil)
    }
}
