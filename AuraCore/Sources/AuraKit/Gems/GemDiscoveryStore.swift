import Foundation
import Observation
import AuraCore

/// Holds the candidate gem set (loaded once) and, as the rider moves, republishes the ambient
/// pins plus the active layer: at most one self-dismissing peek card / haptic per approach.
/// Suppressed while a group ride is active. Solo by construction (see RideHUDView).
@MainActor
@Observable
public final class GemDiscoveryStore {
    public private(set) var visiblePins: [Gem] = []
    public private(set) var activeCard: Gem?
    public private(set) var seenIDs: Set<String> = []
    public private(set) var riderCoordinate: Coordinate?
    public var selectedGem: Gem?
    public var isSuppressed = false {
        didSet { if isSuppressed { visiblePins = []; activeCard = nil } }
    }
    /// Consulted synchronously on the main actor each `update(at:)`. Wired by the HUD to
    /// `{ coordinator.isDetouring }`. While true, the active peek card + Tier-3 gem haptic are
    /// suppressed (turn cues own the cockpit) but pins still render and seen-state is recorded (R7).
    public var detourActive: () -> Bool = { false }

    private let provider: any GemProviding
    private let engine: GemDiscoveryEngine
    private let seen: any SeenGemStoring
    private let haptics: any GemHapticPlaying
    private var candidates: [Gem] = []
    private var state = DiscoveryState()
    private var didLoad = false
    /// The one-time initial load, exposed so callers/tests can await it deterministically.
    public private(set) var loadTask: Task<Void, Never>?

    public init(provider: any GemProviding, engine: GemDiscoveryEngine = .init(),
                seen: any SeenGemStoring, haptics: any GemHapticPlaying) {
        self.provider = provider
        self.engine = engine
        self.seen = seen
        self.haptics = haptics
    }

    /// Loads the candidate set for the current rider coordinate. A no-op until the first
    /// fix — coordinate-filtering providers (live/personal) must never be queried at (0,0).
    /// Fired once from `update(at:now:)`; `now` is captured at fire-time and threaded in.
    public func load(at now: Date) async {
        guard let origin = riderCoordinate else { return }
        candidates = await provider.gems(near: origin)
        seenIDs = seen.seenGemIDs()
        state = DiscoveryState(seenBefore: seenIDs)
        evaluate(at: origin, now: now, detouring: detourActive())
    }

    public func update(at coordinate: Coordinate, now: Date) {
        riderCoordinate = coordinate
        let detouring = detourActive()   // snapshot ONCE at entry — no mid-update re-entrancy flip
        if !didLoad {
            didLoad = true
            loadTask = Task { [now] in await load(at: now) }   // capture now at fire-time
        }
        evaluate(at: coordinate, now: now, detouring: detouring)
    }

    private func evaluate(at coordinate: Coordinate, now: Date, detouring: Bool) {
        guard !isSuppressed else { visiblePins = []; activeCard = nil; return }
        let decision = engine.decide(from: candidates, at: coordinate, now: now, state: &state)
        visiblePins = decision.visiblePins
        if let gem = decision.activeSurfacing {
            seenIDs.insert(gem.id)
            seen.markSeen(gem.id, at: now)
            if !detouring {
                activeCard = gem
                if gem.tier == .cardHaptic { haptics.playGemSurfaced() }
            }
        }
    }

    public func dismissActiveCard() { activeCard = nil }
    public func select(_ gem: Gem) { selectedGem = gem }
    public func clearSelection() { selectedGem = nil }
}

extension GemDiscoveryStore: RideDiscoverySink {
    public func rideDidUpdateLocation(_ point: TrackPoint) {
        update(at: point.coordinate, now: point.timestamp)
    }
}
