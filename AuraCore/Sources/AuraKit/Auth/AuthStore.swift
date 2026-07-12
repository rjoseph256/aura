import Foundation
import Observation
import AuraCore

@Observable
@MainActor
public final class AuthStore {
    public enum Status: Equatable, Sendable { case idle, signingIn, error(String) }

    public private(set) var userID: UUID?
    public var isSignedIn: Bool { userID != nil }
    public private(set) var status: Status = .idle

    @ObservationIgnored private let backend: any GroupRideBackend
    @ObservationIgnored private let apple: any AppleAuthenticating
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var eventTask: Task<Void, Never>?

    static let lastUserIDKey = "auth.lastSignedInUserID"

    public init(backend: any GroupRideBackend, apple: any AppleAuthenticating,
                defaults: UserDefaults = .standard) {
        self.backend = backend
        self.apple = apple
        self.defaults = defaults
        self.userID = backend.cachedUserID    // synchronous cold-launch read (Keychain)
        eventTask = Task { @MainActor [weak self] in
            guard let events = self?.backend.authEvents() else { return }
            for await change in events {
                guard let self else { return }
                switch change {
                case .signedIn(let id): self.userID = id
                case .signedOut: self.userID = nil
                }
            }
        }
    }

    deinit { eventTask?.cancel() }

    public func signInWithApple() async {
        status = .signingIn
        do {
            let cred = try await apple.signIn()
            // Authenticate (auth only — name push is best-effort below so a name
            // failure never fails sign-in).
            try await backend.signIn(idToken: cred.idToken, nonce: cred.rawNonce, displayName: nil)
            let uid = try await backend.currentUserID()

            // Account switch: don't let a prior user's local crew name bleed into a
            // different Apple ID. If we can't seed a fresh name from Apple, clear it so
            // the (now working) name screen prompts instead.
            let previous = defaults.string(forKey: Self.lastUserIDKey)
            if previous != uid.uuidString, cred.fullName == nil {
                defaults.removeObject(forKey: DisplayNameStore.crewDisplayNameKey)
            }
            if let name = cred.fullName, let normalized = DisplayName.normalized(name) {
                try? await backend.renameDisplayName(normalized)             // best-effort
                defaults.set(normalized, forKey: DisplayNameStore.crewDisplayNameKey)
            }
            defaults.set(uid.uuidString, forKey: Self.lastUserIDKey)
            userID = uid
            status = .idle
        } catch AppleAuthError.canceled {
            status = .idle
        } catch {
            status = .error("Couldn't sign in — check your connection and try again.")
        }
    }

    public func signOut() async {
        try? await backend.signOut()
        userID = nil                       // authEvents will also confirm this
    }

    public func deleteAccount() async {
        do {
            try await backend.deleteAccount()
            try? await backend.signOut()
            defaults.removeObject(forKey: DisplayNameStore.crewDisplayNameKey)
            defaults.removeObject(forKey: Self.lastUserIDKey)
            userID = nil
            status = .idle
        } catch {
            status = .error("Couldn't delete your account — try again.")
        }
    }
}
