import Foundation

/// A coordinate, its horizontal accuracy (metres; CLLocation reports < 0 when invalid), and
/// the instant it was observed. `Equatable` so SwiftUI `.onChange` can watch it; `Sendable`
/// so it crosses actor boundaries from delegate callbacks.
public struct LocationFix: Equatable, Sendable {
    public let coordinate: Coordinate
    public let horizontalAccuracy: Double
    public let at: Date
    public init(coordinate: Coordinate, horizontalAccuracy: Double, at: Date) {
        self.coordinate = coordinate
        self.horizontalAccuracy = horizontalAccuracy
        self.at = at
    }
}

/// Why an origin is being requested. Routing needs a precise fix; coarse (weather) tolerates
/// the ~kilometre ambient sample.
public enum LocationPurpose: Sendable { case routing, coarse }

/// Pick a cheap origin without hitting the location hardware, or return nil so the caller falls
/// through to a one-shot request. A fresh cached fix wins — but for `.routing` only if it is also
/// precise (`0 <= horizontalAccuracy <= fineThreshold`), since a coarse cached fix would start a
/// route ~1 km off. The ambient sample is acceptable for `.coarse` only. "Fresh" = within
/// `freshness` of `now`.
public func resolveOrigin(cached: LocationFix?,
                          ambient: LocationFix?,
                          purpose: LocationPurpose,
                          now: Date,
                          freshness: TimeInterval = 30,
                          fineThreshold: Double = 100) -> Coordinate? {
    func isFresh(_ fix: LocationFix) -> Bool { now.timeIntervalSince(fix.at) < freshness }
    func isFine(_ fix: LocationFix) -> Bool { fix.horizontalAccuracy >= 0 && fix.horizontalAccuracy <= fineThreshold }
    if let cached, isFresh(cached), purpose == .coarse || isFine(cached) { return cached.coordinate }
    if purpose == .coarse, let ambient, isFresh(ambient) { return ambient.coordinate }
    return nil
}
