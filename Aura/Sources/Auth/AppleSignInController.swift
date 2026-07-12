import AuthenticationServices
import CryptoKit
import Foundation
import UIKit
import AuraKit

@MainActor
final class AppleSignInController: NSObject, AppleAuthenticating,
                                   ASAuthorizationControllerDelegate,
                                   ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<AppleCredential, Error>?
    private var currentRawNonce: String = ""

    func signIn() async throws -> AppleCredential {
        let rawNonce = Self.randomNonceString()
        currentRawNonce = rawNonce
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName]
        request.nonce = Self.sha256(rawNonce)
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization auth: ASAuthorization) {
        guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = cred.identityToken,
              let token = String(data: tokenData, encoding: .utf8) else {
            continuation?.resume(throwing: AppleAuthError.failed)
            continuation = nil
            return
        }
        let name = [cred.fullName?.givenName, cred.fullName?.familyName]
            .compactMap { $0 }.joined(separator: " ")
        continuation?.resume(returning: AppleCredential(idToken: token, rawNonce: currentRawNonce,
                                                        fullName: name.isEmpty ? nil : name))
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        let mapped: AppleAuthError =
            (error as? ASAuthorizationError)?.code == .canceled ? .canceled : .failed
        continuation?.resume(throwing: mapped)
        continuation = nil
    }

    // Real device requires the app's key window, not a bare ASPresentationAnchor().
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first
        return scene?.keyWindow ?? scene?.windows.first ?? ASPresentationAnchor()
    }

    private static func randomNonceString(length: Int = 32) -> String {
        let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""; var remaining = length
        while remaining > 0 {
            var random: UInt8 = 0
            _ = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
            if random < UInt8(chars.count) { result.append(chars[Int(random)]); remaining -= 1 }
        }
        return result
    }
    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
