// Aura/Sources/Ride/ShareCard/ShareMapSnapshotter.swift
import UIKit
import CoreLocation
import os
import MapboxMaps
import AuraCore
import AuraKit

/// Everything the SDK's off-main callbacks touch, behind one lock. `nonisolated` is
/// REQUIRED: without it, default MainActor isolation infers `@MainActor` onto this
/// class (the `Sendable` conformance does not opt out) and Step 4.7 fails to compile.
/// The completion/overlay handler may arrive on either the SDK's compositor thread
/// or main — the box handles both.
private nonisolated final class SnapshotBox: @unchecked Sendable {
    struct State {
        var finished = false
        var capturedRuns: [[CGPoint]] = []
        /// Strong ref so the render can't be torn down mid-flight (the SDK holds only
        /// weak self and silently drops the completion after dealloc — the Home
        /// continuation-leak lesson). Released ONLY on the main actor, after the await.
        var snapshotter: Snapshotter?
        var continuation: CheckedContinuation<UIImage?, Never>?
    }
    // `uncheckedState:`, not `initialState:` — the latter requires State: Sendable,
    // which stops holding the moment this class is nonisolated (State carries the
    // non-Sendable Snapshotter and continuation on purpose; the lock is the guarantee).
    private let lock = OSAllocatedUnfairLock<State>(uncheckedState: State())

    func store(snapshotter: Snapshotter, continuation: CheckedContinuation<UIImage?, Never>) {
        lock.withLockUnchecked { $0.snapshotter = snapshotter; $0.continuation = continuation }
    }
    /// Overlay capture; drops writes after the latch resolves (spec §Route drawing 1).
    func capture(_ runs: [[CGPoint]]) {
        lock.withLockUnchecked { if !$0.finished { $0.capturedRuns = runs } }
    }
    /// Resolve-once. Safe from any thread; resumes the continuation at most once.
    func finish(with image: UIImage?) {
        let cont: CheckedContinuation<UIImage?, Never>? = lock.withLockUnchecked {
            guard !$0.finished else { return nil }
            // The store-before-start ordering is enforced only by line adjacency in
            // renderMapRasterWithChrome; a resolver firing before store() would latch
            // with no continuation to resume and wedge the pipeline permanently.
            // Debug-only signal — release behavior is identical.
            if $0.continuation == nil {
                assertionFailure("SnapshotBox.finish before store(_:continuation:) — latch would wedge")
            }
            $0.finished = true
            let c = $0.continuation; $0.continuation = nil
            return c
        }
        cont?.resume(returning: image)
    }
    var runs: [[CGPoint]] { lock.withLockUnchecked { $0.capturedRuns } }
    /// For the timeout arm: a strong ref IF unfinished (cancel-before-release ordering).
    func snapshotterIfUnfinished() -> Snapshotter? {
        lock.withLockUnchecked { $0.finished ? nil : $0.snapshotter }
    }
    /// Called on the main actor only, after the await returns.
    func releaseSnapshotter() { lock.withLockUnchecked { $0.snapshotter = nil } }
}

/// The rejected flag the `onMapLoadingError` observer writes from the SDK's compositor
/// thread. `nonisolated` is REQUIRED for the same reason as `SnapshotBox`;
/// `initialState:` is fine here because the state is Sendable. `.style`/`.source`
/// errors reject; `.tile` errors only log (edge tiles 404 routinely — DEM outside
/// coverage — and Home's precedent only logs; the interior-variance check is the
/// primary defense for partial tiles). `.glyphs`/`.sprite` fall to the `default`
/// branch and are deliberately ignored as cosmetic.
private nonisolated final class MapLoadErrorFlags: @unchecked Sendable {
    private static let log = Logger(subsystem: "app.aura.ios", category: "ShareCard")
    private let lock = OSAllocatedUnfairLock(initialState: false)

    func record(_ error: MapLoadingError) {
        switch error.type {
        case .style, .source:
            lock.withLock { $0 = true }
        case .tile:
            Self.log.warning("share-map tile load error (non-fatal): \(error.message, privacy: .public)")
        default:
            break
        }
    }

    var rejected: Bool { lock.withLock { $0 } }
}

/// Style-load latch outcome. Timeout is distinct from failure on purpose: the caller
/// consults `isStyleLoaded` back on the main actor, so the belt's timeout closure never
/// has to capture the non-Sendable snapshotter.
private nonisolated enum StyleLoadOutcome: Sendable {
    case loaded
    case failed
    case timedOut
}

/// Outcome of racing an in-flight pipeline task against the slot watchdog's ceiling.
private nonisolated enum SlotAwaitOutcome: Sendable {
    case finished(UIImage?)
    case ceiling
}

/// The app-lifetime share-map raster provider (spec ROH-126 rev 4): at most one
/// `Snapshotter` pipeline alive at a time, single-flight per cache key, composited
/// results disk-cached under `Caches/ShareCardSnapshots`. There is deliberately NO
/// negative cache: a rejected pipeline (offline, partial tiles, degenerate camera)
/// re-runs in full on the next request — e.g. a History open after an offline reject
/// re-runs the ≤10 s pipeline with the hint up. That is the spec's accepted cost.
///
/// Instance identity is load-bearing: the single-flight dedup table and the
/// one-pipeline-at-a-time invariant live on the instance, so a second concrete
/// instance would silently defeat both. `shared` + `private init` make that a
/// compile error rather than a code-review catch; stubbing still goes through the
/// `ShareMapRasterProviding` seam and `ShareMapProviderBox`.
@MainActor final class ShareMapSnapshotter: ShareMapRasterProviding {
    static let shared = ShareMapSnapshotter()
    private init() {}

    /// Every reject path logs its reason: a nil from this pipeline is invisible in the
    /// UI by design (the card just stays on the polyline fallback), so without a trace
    /// a rejection is indistinguishable from a hang in the field and in verification.
    /// `nonisolated` so the detached acceptance step can log too (Logger is Sendable).
    private nonisolated static let log = Logger(subsystem: "app.aura.ios", category: "ShareCard")

    /// `id` is the slot's identity: the watchdog and the pipeline's own defer may
    /// only clear the slot while it still holds THEIR identity, never a successor's.
    private struct InFlightSlot {
        let key: String
        let id: UUID
        let task: Task<UIImage?, Never>
    }
    private var inFlight: InFlightSlot?
    private let cache = TerrainSnapshotDiskCache(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "ShareCardSnapshots"))   // its own directory — sharing Home's
                                                      // TerrainSnapshots would let two prune
                                                      // budgets evict each other's files

    func raster(for request: ShareMapRequest) async -> UIImage? {
        // Fast path, BEFORE the same-key join and the wait loop: a warm cache hit must
        // not queue behind an unrelated in-flight pipeline (~10 s worst case, reproduced
        // in review). Small file read on main — same balance as the in-pipeline read.
        // The image binding is load-bearing: returning nil on a corrupt-but-present
        // entry would pin the fallback card forever; falling through re-renders and
        // overwrites the bad file.
        if let data = cache.read(request.cacheKey), let image = UIImage(data: data, scale: request.scale) {
            return image
        }
        if let inFlight, inFlight.key == request.cacheKey {
            return await boundedValue(of: inFlight.task, slotID: inFlight.id)
        }
        while let current = inFlight {                                  // suspends, no spin
            _ = await boundedValue(of: current.task, slotID: current.id)
        }
        // No await between the loop exit and this assignment (single-pipeline invariant).
        let slotID = UUID()
        let task = Task { [weak self] in await self?.runPipelineReleasingSlot(request, slotID: slotID) ?? nil }
        inFlight = InFlightSlot(key: request.cacheKey, id: slotID, task: task)
        return await boundedValue(of: task, slotID: slotID)
    }

    /// Races the pipeline task against a 20 s ceiling. The pipeline's detached steps
    /// (encode / cache write / prune) are unbounded, and a wedged pipeline would
    /// otherwise poison this app-lifetime provider for the whole session: the slot
    /// would never clear and every later request would park behind it forever. On
    /// ceiling, clear the slot ONLY if it still holds this identity (the pipeline's
    /// own defer, or a successor claiming the slot, may have raced us) and hand the
    /// caller nil. Resolve-once latch, same shape as `loadStyle`.
    private func boundedValue(of task: Task<UIImage?, Never>, slotID: UUID) async -> UIImage? {
        let outcome: SlotAwaitOutcome = await withCheckedContinuation { cont in
            let done = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finishOnce(_ value: SlotAwaitOutcome) {
                done.withLock { resumed in
                    if !resumed { resumed = true; cont.resume(returning: value) }
                }
            }
            Task { finishOnce(.finished(await task.value)) }
            Task {
                try? await Task.sleep(for: .seconds(20))
                finishOnce(.ceiling)
            }
        }
        switch outcome {
        case .finished(let image): return image
        case .ceiling:
            if inFlight?.id == slotID { inFlight = nil }
            return nil
        }
    }

    /// Owns the in-flight slot's lifetime: cleared on EVERY exit, including the
    /// cache-hit and reject early returns. Do not move this into runPipeline —
    /// runPipeline is nothing but early returns, and a "clear at the end" only runs
    /// on the full-success path: every failure (offline reject, the headline error
    /// path) would leave a completed task in the slot forever, wedging same-key
    /// retries and LIVELOCKING different-key waiters' while-loop on the main actor
    /// (reproduced in plan delta-review). This is the spec's normative `defer`.
    /// Keyed on the slot's IDENTITY, not its cache key: after a watchdog ceiling a
    /// successor (possibly same-key) may occupy the slot, and a late-finishing wedged
    /// pipeline must not clear it out from under that successor.
    private func runPipelineReleasingSlot(_ request: ShareMapRequest, slotID: UUID) async -> UIImage? {
        defer { if inFlight?.id == slotID { inFlight = nil } }
        return await runPipeline(request)
    }

    // MARK: - Pipeline

    private func runPipeline(_ request: ShareMapRequest) async -> UIImage? {
        MainActor.assertIsolated()
        // The cache stores the COMPOSITED image — a hit returns as-is: it carries no
        // projected points and never needs a re-composite (spec step 2). Kept even
        // though raster(for:) probes first: a request that queued behind another
        // pipeline BEFORE its key was cached still hits here instead of re-rendering.
        // Corrupt entries fall through to a re-render that overwrites them.
        if let data = cache.read(request.cacheKey), let image = UIImage(data: data, scale: request.scale) {
            return image
        }

        let snapshotter = Snapshotter(options: MapSnapshotOptions(
            size: request.size,
            pixelRatio: request.scale,
            glyphsRasterizationOptions: GlyphsRasterizationOptions(rasterizationMode: .ideographsRasterizedLocally)))

        // Observer attached BEFORE the load and alive through start(); token cancelled
        // on every exit.
        let errorFlags = MapLoadErrorFlags()
        let errorToken = snapshotter.onMapLoadingError.observe { @Sendable error in errorFlags.record(error) }
        defer { errorToken.cancel() }

        guard await loadStyle(request.style.mapboxStyle, into: snapshotter) else {
            Self.log.info("share-map reject: style load failed or timed out")
            return nil
        }
        // Rejected read 1 of 2: a style/source error surfaced during the load.
        guard !errorFlags.rejected else {
            Self.log.info("share-map reject: style/source loading error")
            return nil
        }
        guard fitCamera(snapshotter, to: request) else {
            Self.log.info("share-map reject: degenerate camera fit")
            return nil
        }
        // Rejected read 2 of 2 sits inside renderMapRasterWithChrome, after the render resolves.
        guard let (raster, runs) = await renderMapRasterWithChrome(snapshotter, request: request, flags: errorFlags)
        else {
            Self.log.info("share-map reject: render failed, timed out, mid-render error, or no captured route")
            return nil
        }
        guard await passesAcceptance(raster, key: request.cacheKey) else {
            Self.log.info("share-map reject: raster failed the non-blank interior check")
            return nil
        }

        // Hoisted ON MAIN: the detached composite must not read @MainActor theme statics
        // (today that is only a warning, so a green build would hide the race).
        let casing = AuraTheme.routeCasingUIColor.cgColor
        let mint = AuraTheme.routeUIColor.cgColor
        let composited = await Task.detached(priority: .utility) {
            Self.composite(raster: raster, runs: runs, size: request.size, scale: request.scale,
                           colors: (casing: casing, mint: mint))
        }.value
        guard let composited else {   // nil route path → reject BEFORE any cache write
            Self.log.info("share-map reject: no strokeable route path at composite")
            return nil
        }

        await persist(composited, key: request.cacheKey)
        Self.log.info("share-map accepted and cached")
        return composited
    }

    /// Style load with its OWN resolve-once latch — a `MapStyleReconciler` completion can
    /// fire synchronously, and a double resume is a crash — raced against a 4 s belt
    /// (the Home-gate shape). Never also touches `styleJSON`/`styleURI`: a second load
    /// parks in `pendingCompletions` and can hang.
    private func loadStyle(_ style: MapboxMaps.MapStyle, into snapshotter: Snapshotter) async -> Bool {
        let outcome: StyleLoadOutcome = await withCheckedContinuation { cont in
            let done = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finishOnce(_ value: StyleLoadOutcome) {
                done.withLock { resumed in
                    if !resumed { resumed = true; cont.resume(returning: value) }
                }
            }
            snapshotter.load(mapStyle: style) { @Sendable error in
                finishOnce(error == nil ? .loaded : .failed)   // non-nil load error → reject
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { finishOnce(.timedOut) }
        }
        switch outcome {
        case .loaded: return true
        case .failed: return false
        // Belt timeout: the completion may be parked while the style actually loaded —
        // consult `isStyleLoaded` before rejecting (spec step 3). Legal here: this method
        // is back on the main actor after the await.
        case .timedOut: return snapshotter.isStyleLoaded
        }
    }

    /// Camera fit, strictly AFTER the style load — a style's root `center`/`zoom` would
    /// otherwise override the fit (spec step 4).
    private func fitCamera(_ snapshotter: Snapshotter, to request: ShareMapRequest) -> Bool {
        let coords = request.route.segments.flatMap { segment in
            segment.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        }
        var cam = snapshotter.camera(for: coords,
                                     padding: UIEdgeInsets(top: ShareCardLayout.cameraPaddingTop,
                                                           left: ShareCardLayout.cameraPaddingSides,
                                                           bottom: ShareCardLayout.cameraPaddingBottom,
                                                           right: ShareCardLayout.cameraPaddingSides),
                                     bearing: 0, pitch: 0)
        guard let validated = ShareCameraValidation.validated(latitude: cam.center?.latitude,
                                                              longitude: cam.center?.longitude,
                                                              zoom: cam.zoom.map { Double($0) })
        else { return false }
        // MUTATE the returned options — replace zoom only — and set the whole thing back.
        // Never rebuild them: the SDK-returned `padding` is the sole enforcement of the
        // route-clear-of-chrome ToS invariant (ShareCameraValidation's usage rule).
        cam.zoom = CGFloat(validated.zoom)
        snapshotter.setCamera(to: cam)
        return true
    }

    /// Render, bounded and resume-once (spec step 5): the box owns everything the SDK's
    /// off-main callbacks touch, and the 6 s timeout arm cancels BEFORE resolving the
    /// latch. The raster is route-free but NOT chrome-free — it carries the SDK's
    /// logo/attribution band; the route ink is composited on later.
    private func renderMapRasterWithChrome(
        _ snapshotter: Snapshotter, request: ShareMapRequest, flags: MapLoadErrorFlags
    ) async -> (raster: UIImage, runs: [[CGPoint]])? {
        let box = SnapshotBox()
        let raster: UIImage? = await withCheckedContinuation { cont in
            box.store(snapshotter: snapshotter, continuation: cont)
            snapshotter.start(
                overlayHandler: { @Sendable overlay in
                    // projectedRuns MUST be `nonisolated static func` (default isolation would
                    // make it @MainActor and this call a compile error).
                    box.capture(Self.projectedRuns(request.route.segments, overlay.pointForCoordinate))
                },
                completion: { @Sendable result in
                    box.finish(with: (try? result.get()))
                })
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                // Cancel BEFORE the latch resolves-and-releases: finish() first would let the
                // ref go before cancel() ran (rev 1's bug: cancel() was a guaranteed no-op).
                box.snapshotterIfUnfinished()?.cancel()   // main thread; may itself fire completion
                box.finish(with: nil)
            }
        }
        box.releaseSnapshotter()          // main actor, after the await — never off-main deinit
        // Rejected read 2 of 2: a style error surfacing mid-render discards the raster.
        guard !flags.rejected, let raster else { return nil }
        let runs = box.runs
        guard runs.contains(where: { $0.count >= 2 }) else { return nil }   // no route captured →
                                                                            // never ship a routeless map card
        return (raster, runs)
    }

    /// Acceptance on the pre-composite map raster, off-main (spec step 6): downsample to exactly 90×60
    /// grayscale (size/4 in points) and require interior texture outside the chrome strip.
    /// On rejection, the per-cell deviations are logged — the threshold was tuned against
    /// these numbers from real captures, and re-tuning needs them visible in the field.
    private func passesAcceptance(_ raster: UIImage, key: String) async -> Bool {
        let width = 90, height = 60
        let strip = ShareCardLayout.mapChromeStripHeight / ShareCardLayout.mapFieldSize.height
        let excludedBottomRows = Int((strip * CGFloat(height)).rounded(.up))   // 36/240 × 60 → 9
        return await Task.detached(priority: .utility) { () -> Bool in
            Self.dumpRasterIfRequested(raster, key: key)
            guard let pixels = Self.grayscalePixels(of: raster, width: width, height: height) else { return false }
            let accepted = ShareRasterAcceptance.accepts(pixels: pixels, width: width, height: height,
                                                         excludedBottomRows: excludedBottomRows)
            if !accepted {
                let cells = ShareRasterAcceptance.cellDeviations(
                    pixels: pixels, width: width, height: height, excludedBottomRows: excludedBottomRows)
                let summary = cells.map { String(format: "%.1f", $0) }.joined(separator: " ")
                let threshold = ShareRasterAcceptance.stddevThreshold
                Self.log.info("share-map acceptance cells (stddev, threshold \(threshold)): \(summary, privacy: .public)")
            }
            return accepted
        }.value
    }

    /// Debug escape hatch for threshold tuning: `AURA_SHARE_MAP_DUMP=1` in the
    /// environment writes every pre-composite raster to tmp/ShareCardDebug/. DEBUG only.
    private nonisolated static func dumpRasterIfRequested(_ raster: UIImage, key: String) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["AURA_SHARE_MAP_DUMP"] == "1",
              let data = raster.pngData() else { return }
        let dir = FileManager.default.temporaryDirectory.appending(path: "ShareCardDebug")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appending(path: "\(key).png"), options: .atomic)
        #endif
    }

    /// Encode + cache write + prune, off the main actor (spec step 7). Awaited so a
    /// finished pipeline task has always already written the cache.
    private func persist(_ image: UIImage, key: String) async {
        let cache = self.cache
        await Task.detached(priority: .utility) {
            guard let data = image.pngData() else { return }
            cache.write(data, for: key)
            cache.prune(toMaxBytes: 24 * 1024 * 1024)
        }.value
    }

    // MARK: - Pure helpers (off-main capable)

    /// Projects each ride segment through the snapshot's coordinate→point transform, one
    /// run per segment so pause gaps stay separate subpaths. `nonisolated static` is
    /// load-bearing: default isolation would make this `@MainActor` and the off-main
    /// overlay call a compile error.
    private nonisolated static func projectedRuns(
        _ segments: [[Coordinate]], _ point: (CLLocationCoordinate2D) -> CGPoint
    ) -> [[CGPoint]] {
        segments.map { segment in
            segment.map { point(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)) }
        }
    }

    /// Downsampled grayscale buffer for `ShareRasterAcceptance`. `bytesPerRow: width` is
    /// explicit and load-bearing: CG's default alignment padding would break the
    /// `count == width * height` guard and silently reject every raster.
    private nonisolated static func grayscalePixels(of image: UIImage, width: Int, height: Int) -> [UInt8]? {
        guard let cgImage = image.cgImage else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    /// The composite pass (spec §Route drawing): raster first via `UIImage.draw(in:)` —
    /// NOT `context.draw`, which flips the map upside down under a correctly-oriented
    /// route — then the route stroked twice off one path, casing under mint, round
    /// caps/joins. `nil` when no strokeable run exists: the pipeline rejects rather than
    /// cache or ship a routeless map card.
    private nonisolated static func composite(
        raster: UIImage, runs: [[CGPoint]], size: CGSize, scale: CGFloat,
        colors: (casing: CGColor, mint: CGColor)
    ) -> UIImage? {
        guard let path = ShareRoutePath.path(runs: runs) else { return nil }
        let format = UIGraphicsImageRendererFormat()   // no `init(scale:)` exists
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { rendererContext in
            raster.draw(in: CGRect(origin: .zero, size: size))
            let context = rendererContext.cgContext
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(path)
            context.setLineWidth(ShareCardLayout.routeCasingWidth)
            context.setStrokeColor(colors.casing)
            context.strokePath()
            context.addPath(path)
            context.setLineWidth(ShareCardLayout.routeStrokeWidth)
            context.setStrokeColor(colors.mint)
            context.strokePath()
        }
    }
}
