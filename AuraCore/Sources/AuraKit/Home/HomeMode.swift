import Foundation

/// Which Home composition to show. First-run is its own composition; everything else is the
/// populated layout (which itself handles the no-permission case via the curated default).
public enum HomeMode: Sendable { case firstRun, populated }

public extension HomeMode {
    /// First-run only when the user has never completed onboarding AND has no rides AND has
    /// not yet answered the location prompt. Any ride, or a determined auth state (denied,
    /// restricted, or authorized), means a returning user → populated (with the curated
    /// default region when location is unavailable). Reuses the app-wide
    /// `LocationAuthorization` projection rather than a parallel enum.
    static func resolve(hasCompletedOnboarding: Bool, hasRides: Bool,
                        auth: LocationAuthorization) -> HomeMode {
        if hasRides || hasCompletedOnboarding { return .populated }
        return auth == .notDetermined ? .firstRun : .populated
    }
}
