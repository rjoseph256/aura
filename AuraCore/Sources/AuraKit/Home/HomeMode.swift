import Foundation

/// A CoreLocation-free authorization projection so the predicate stays pure/testable on CI;
/// the app maps `CLAuthorizationStatus` onto it.
public enum LocationAuthState: Sendable { case notDetermined, denied, authorized }

/// Which Home composition to show. First-run is its own composition; everything else is the
/// populated layout (which itself handles the no-permission case via the curated default).
public enum HomeMode: Sendable { case firstRun, populated }

public extension HomeMode {
    /// First-run only when the user has never completed onboarding AND has no rides AND has
    /// not yet answered the location prompt. Any ride, or a determined auth state, means a
    /// returning user → populated (with the curated default when location is unavailable).
    static func resolve(hasCompletedOnboarding: Bool, hasRides: Bool, auth: LocationAuthState) -> HomeMode {
        if hasRides || hasCompletedOnboarding { return .populated }
        return auth == .notDetermined ? .firstRun : .populated
    }
}
