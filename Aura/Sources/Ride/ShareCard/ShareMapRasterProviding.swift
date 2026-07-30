// Aura/Sources/Ride/ShareCard/ShareMapRasterProviding.swift
import UIKit
import Observation
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
    /// The accepted, composited card map — raster plus route ink — or `nil`, which means
    /// exactly: no acceptable map; the card keeps the polyline fallback.
    func raster(for request: ShareMapRequest) async -> UIImage?
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
}
