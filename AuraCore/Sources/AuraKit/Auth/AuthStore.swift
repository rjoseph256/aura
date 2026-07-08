import Foundation
import Observation

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
}
