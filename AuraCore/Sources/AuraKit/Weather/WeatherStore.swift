import Foundation
import Observation
import AuraCore

/// Holds the latest weather snapshot for the greeting. `@MainActor` (SwiftUI-facing state) and
/// `@Observable` so the greeting re-renders when it lands. Time is push-injected (`now:`) so the
/// cache and staleness rules are deterministic in tests. Never imports WeatherKit — the concrete
/// fetch is behind the `WeatherProviding` seam, injected by the app composition root.
@MainActor
@Observable
public final class WeatherStore {
    public private(set) var snapshot: WeatherSnapshot?

    @ObservationIgnored private let provider: WeatherProviding
    @ObservationIgnored private let cacheAge: TimeInterval = 15 * 60
    @ObservationIgnored private let cacheDistance: Double = 2_000
    @ObservationIgnored private let staleAfter: TimeInterval = 60 * 60

    public init(provider: WeatherProviding) {
        self.provider = provider
    }

    /// Fetches conditions near `coordinate`, unless a recent snapshot (< 15 min old and within
    /// ~2 km) already covers it. On failure the last snapshot is left untouched (silent hide).
    public func refresh(near coordinate: Coordinate, now: Date) async {
        if let s = snapshot,
           now.timeIntervalSince(s.asOf) < cacheAge,
           Geo.distance(s.coordinate, coordinate) < cacheDistance {
            return
        }
        do {
            snapshot = try await provider.currentConditions(for: coordinate)
        } catch {
            // Leave `snapshot` unchanged; the greeting simply omits weather.
        }
    }

    /// The snapshot to display, or nil once it is older than the staleness bound.
    public func displaySnapshot(now: Date) -> WeatherSnapshot? {
        guard let s = snapshot, now.timeIntervalSince(s.asOf) < staleAfter else { return nil }
        return s
    }
}
