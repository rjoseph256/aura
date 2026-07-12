import Testing
@testable import AuraKit

struct AppleAuthenticatingTests {
    struct FakeApple: AppleAuthenticating {
        let result: Result<AppleCredential, AppleAuthError>
        func signIn() async throws -> AppleCredential { try result.get() }
    }

    @Test func returnsCredential() async throws {
        let fake = FakeApple(result: .success(AppleCredential(idToken: "tok", rawNonce: "nonce", fullName: "Rohun")))
        let cred = try await fake.signIn()
        #expect(cred.idToken == "tok")
        #expect(cred.rawNonce == "nonce")
        #expect(cred.fullName == "Rohun")
    }

    @Test func propagatesCanceled() async {
        let fake = FakeApple(result: .failure(.canceled))
        await #expect(throws: AppleAuthError.canceled) { try await fake.signIn() }
    }
}
