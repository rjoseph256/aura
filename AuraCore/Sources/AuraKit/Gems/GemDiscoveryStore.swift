import Foundation
import Observation
import AuraCore

/// Holds the candidate gem set (loaded once) and republishes the visible pins as the
/// rider moves. Suppressed while a group ride is active (peer dots own the map budget).
@MainActor
@Observable
public final class GemDiscoveryStore {
    public private(set) var visiblePins: [Gem] = []
    public var isSuppressed = false {
        didSet { if isSuppressed { visiblePins = [] } }
    }

    private let provider: any GemProviding
    private let engine: GemDiscoveryEngine
    private var candidates: [Gem] = []
    private var lastCoordinate: Coordinate?

    public init(provider: any GemProviding, engine: GemDiscoveryEngine = .init()) {
        self.provider = provider
        self.engine = engine
    }

    public func load() async {
        // The (0,0) fallback origin is only safe because the curated provider ignores
        // `near:` and returns its whole set. A coordinate-filtering provider (the future
        // live feed) must NOT be loaded at (0,0): defer `load()` until the first fix has
        // set `lastCoordinate`, or fetch per-fix, or this queries gems near Null Island.
        let origin = lastCoordinate ?? Coordinate(latitude: 0, longitude: 0)
        candidates = await provider.gems(near: origin)
        if let coordinate = lastCoordinate { update(at: coordinate) }
    }

    public func update(at coordinate: Coordinate) {
        lastCoordinate = coordinate
        guard !isSuppressed else { visiblePins = []; return }
        visiblePins = engine.visiblePins(from: candidates, at: coordinate)
    }
}

extension GemDiscoveryStore: RideDiscoverySink {
    public func rideDidUpdateLocation(_ point: TrackPoint) { update(at: point.coordinate) }
}
