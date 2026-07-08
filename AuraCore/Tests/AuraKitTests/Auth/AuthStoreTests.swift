import Testing
import Foundation
@testable import AuraKit

@MainActor struct AuthStoreTests {
    private func store(_ b: InMemoryGroupRideBackend,
                       _ apple: AppleAuthenticating = FakeApple(.success(AppleCredential(idToken: "t", rawNonce: "n", fullName: "Rohun"))),
                       defaults: UserDefaults) -> AuthStore {
        AuthStore(backend: b, apple: apple, defaults: defaults)
    }
    struct FakeApple: AppleAuthenticating {
        let r: Result<AppleCredential, AppleAuthError>
        init(_ r: Result<AppleCredential, AppleAuthError>) { self.r = r }
        func signIn() async throws -> AppleCredential { try r.get() }
    }

    @Test func coldLaunchReadsCachedSession() async throws {
        let b = InMemoryGroupRideBackend()
        try await b.signIn(idToken: "t", nonce: "n", displayName: nil)   // pre-existing session
        let d = UserDefaults(suiteName: "auth.cold.\(UUID())")!
        let s = AuthStore(backend: b, apple: FakeApple(.success(.init(idToken: "t", rawNonce: "n", fullName: nil))), defaults: d)
        #expect(s.isSignedIn == true)
        #expect(s.userID == b.cachedUserID)
    }

    @Test func startsSignedOutWhenNoSession() async {
        let d = UserDefaults(suiteName: "auth.out.\(UUID())")!
        let s = AuthStore(backend: InMemoryGroupRideBackend(),
                          apple: FakeApple(.success(.init(idToken: "t", rawNonce: "n", fullName: nil))), defaults: d)
        #expect(s.isSignedIn == false)
    }
}
