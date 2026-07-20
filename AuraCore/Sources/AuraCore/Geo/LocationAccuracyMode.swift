import Foundation

/// Desired-accuracy / activity tier. The service maps these to CoreLocation:
/// `.idle` = released (coarse, no updates), `.ambient` = coarse continuous for
/// Home weather (foreground only, no background session/indicator), `.navigating`
/// = the cycling tier while recording (background session + indicator).
public enum LocationAccuracyMode: Sendable, Equatable {
    case idle, ambient, navigating
}

public extension LocationAccuracyMode {
    /// The tier the app should be in, given ride/home/authorization state. Pure so it is
    /// unit-testable without CoreLocation. `isHomeForeground` folds "Home is the top of the
    /// nav stack AND the app is foreground (not backgrounded)" into one flag at the call site.
    /// A ride always wins; ambient needs Home-foreground + authorization; otherwise idle.
    static func desired(isRideActive: Bool, isHomeForeground: Bool, authorized: Bool) -> LocationAccuracyMode {
        if isRideActive { return .navigating }
        if isHomeForeground && authorized { return .ambient }
        return .idle
    }
}
