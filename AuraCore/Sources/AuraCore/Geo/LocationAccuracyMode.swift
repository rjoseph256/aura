import Foundation

/// Desired-accuracy tier. The service maps these to CoreLocation accuracy constants:
/// coarse when idle (battery), the cycling tier while recording.
public enum LocationAccuracyMode: Sendable, Equatable {
    case idle, navigating
}
