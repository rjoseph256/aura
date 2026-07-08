import Foundation

/// The native Apple identity token + the RAW nonce (Apple received sha256(rawNonce)),
/// plus the full name Apple returns only on the first authorization.
public struct AppleCredential: Sendable, Equatable {
    public let idToken: String
    public let rawNonce: String
    public let fullName: String?
    public init(idToken: String, rawNonce: String, fullName: String?) {
        self.idToken = idToken; self.rawNonce = rawNonce; self.fullName = fullName
    }
}

/// AuraKit-side error so `AuthStore` can distinguish a user cancel (silent) from a
/// real failure without importing AuthenticationServices. The app-target adapter maps
/// `ASAuthorizationError.canceled` -> `.canceled`, everything else -> `.failed`.
public enum AppleAuthError: Error, Equatable, Sendable { case canceled, failed }

/// Seam over the native Sign in with Apple flow. The live conformer
/// (`AppleSignInController`) lives in the app target; tests inject a fake.
public protocol AppleAuthenticating: Sendable {
    func signIn() async throws -> AppleCredential
}
