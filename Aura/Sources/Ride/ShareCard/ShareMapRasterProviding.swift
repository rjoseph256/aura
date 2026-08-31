// Aura/Sources/Ride/ShareCard/ShareMapRasterProviding.swift
import UIKit
import Observation
import AuraCore
import AuraKit

/// Seam for the share card's map raster (spec ROH-126 rev 4, §`ShareMapRasterProviding`)
/// — the Home `TerrainSnapshotRendering` pattern, with one difference that matters:
/// instance identity is load-bearing. The single-flight dedup table lives on the
/// provider, so the app owns exactly one instance for its whole lifetime and every call
/// site (ride-end prefetch, summary upgrade, History reopen) must reach that instance.
/// `Sendable` refinement: the HUDs' detached prefetch tasks capture the existential, and
/// without it `any ShareMapRasterProviding` cannot cross into the task. It costs conformers
/// nothing — a `@MainActor` type is implicitly Sendable already.
@MainActor
protocol ShareMapRasterProviding: Sendable {
    /// The accepted, composited card map — raster plus route ink — or which flavour of "no map"
    /// this was. See `ShareMapOutcome`.
    func raster(for request: ShareMapRequest) async -> ShareMapOutcome
}

/// What one share-map request produced.
///
/// Replaces a bare `UIImage?`, which collapsed three situations into one `nil`. ROH-161 needs
/// them apart, because a design that offers the rider a retry has to know whether that retry is a
/// real second attempt: `SharePipelineSlot` deliberately stops a *caller* waiting without
/// stopping the *pipeline* (`SlotOutcome`), and at ride end the summary is specifically the
/// waiter — the HUD prefetch claims the slot at +0.7 s.
enum ShareMapOutcome: Equatable {
    /// An accepted, composited card map.
    case map(UIImage)
    /// The pipeline ran and produced nothing. There is no negative cache, so a retry re-runs it
    /// in full.
    case rejected
    /// A ceiling fired. The pipeline may still be alive and holding the slot, so a retry may
    /// warm-hit a cache it fills later, or re-join it, rather than starting fresh.
    case stoppedWaiting
}

extension ShareMapOutcome {
    /// For callers that only want the image and treat every "no map" the same — the ride-end
    /// prefetch, and the summary until ROH-161's phase wiring lands.
    var image: UIImage? {
        if case .map(let image) = self { return image }
        return nil
    }
}

/// Environment carrier for the app's one provider instance. Environment injection over
/// constructor injection is a recorded plan decision: a future un-injected host crashes
/// at runtime instead of failing to compile, but no parameter plumbs through two routers,
/// and both current presentation sites (push + History sheet) inherit the root
/// environment.
@Observable @MainActor
final class ShareMapProviderBox {
    let provider: any ShareMapRasterProviding

    init(provider: any ShareMapRasterProviding) {
        self.provider = provider
    }

    /// Ride-end share-map prefetch, shared by both HUDs' finished-ride handlers so the
    /// lockstep invariant below lives in exactly one place. Detached + delayed: the
    /// whole-track walk (segment flattening plus `ShareRouteGeometry.prepare` inside the
    /// request init) runs off-frame in the detached task, clear of the summary push
    /// transition; the summary's own request (t≈0.8 s) dedups onto this via the shared
    /// provider instance. The mapped/filtered expression must stay in lockstep with
    /// `ShareCardContent.routeSegments`, or the cache keys diverge and the prefetch is
    /// wasted. Stats-less rides render no Share section at all (`RideSummaryView` gates
    /// on `ride.stats`), so they don't burn a pipeline.
    func prefetchShareMap(for ride: Ride, style: MapStyle) {
        guard ride.stats != nil else { return }
        let provider = provider
        let segments = ride.segments   // RideSegment is Sendable; the walk stays deferred
        let rideID = ride.id
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(0.7))
            let routeSegments = segments.map { $0.points.map(\.coordinate) }.filter { $0.count > 1 }
            guard let request = ShareMapRequest(rideID: rideID, segments: routeSegments,
                                                style: style) else { return }
            _ = await provider.raster(for: request)
        }
    }
}
