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
            // A resolver firing before store() would latch with no continuation to resume
            // and wedge the pipeline permanently. There are now TWO resolvers and they
            // are ordered by different things: the completion and the 6 s belt by line
            // adjacency in renderMapRasterWithChrome, and the cancellation arm by that
            // method's `MainActor.assertIsolated()` plus its main-queue hop. Neither is
            // enforced here. Debug-only signal — release behavior is identical.
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
/// has to capture the non-Sendable snapshotter. `cancelled` is distinct from both so the
/// reject log says which of the three actually happened.
private nonisolated enum StyleLoadOutcome: Sendable {
    case loaded
    case failed
    case timedOut
    case cancelled
}

/// The app-lifetime share-map raster provider (spec ROH-126 rev 4): at most one
/// `Snapshotter` pipeline alive at a time, single-flight per cache key, composited
/// results disk-cached under `Caches/ShareCardSnapshots`. There is deliberately NO
/// negative cache: a rejected pipeline (offline, partial tiles, degenerate camera)
/// re-runs in full on the next request — e.g. a History open after an offline reject
/// re-runs the ≤10 s pipeline with the hint up. That is the spec's accepted cost.
///
/// Instance identity is load-bearing: the `SharePipelineSlot` that enforces both
/// invariants lives on the instance, so a second concrete instance would silently defeat
/// them. `shared` + `private init` make that a compile error rather than a code-review
/// catch; stubbing still goes through the `ShareMapRasterProviding` seam and
/// `ShareMapProviderBox`.
@MainActor final class ShareMapSnapshotter: ShareMapRasterProviding {
    static let shared = ShareMapSnapshotter()
    private init() {}

    /// Every reject path logs its reason: a nil from this pipeline is invisible in the
    /// UI by design (the card just stays on the polyline fallback), so without a trace
    /// a rejection is indistinguishable from a hang in the field and in verification.
    /// `nonisolated` so the detached acceptance step can log too (Logger is Sendable).
    private nonisolated static let log = Logger(subsystem: "app.aura.ios", category: "ShareCard")

    /// The single-flight / one-pipeline-at-a-time machine, in AuraKit so it is
    /// package-testable (`SharePipelineSlotTests`). It used to live inline here, where the
    /// app target's lack of any unit-test target put it out of reach of a test — which is
    /// where the review found the ceiling arm clearing the slot out from under a live
    /// pipeline. The slot now clears only when a pipeline actually unwinds, so the
    /// contract this class has to hold up is that cancellation is real: see
    /// `cancelled(before:)` and the two `withTaskCancellationHandler` arms below.
    private let slot = SharePipelineSlot<UIImage>(onCeiling: { key, isOwner in
        // The wedge this design cannot recover from is silent otherwise: a pipeline that
        // ignores cancellation keeps the slot for the life of the process and every later
        // request just returns nil after its own ceiling. A run of these lines for
        // different keys is that failure, and the only way it reaches a sysdiagnose.
        let role = isOwner ? "owner, pipeline cancelled" : "waiter"
        log.info("share-map ceiling at 20 s (\(role, privacy: .public)) for key \(key, privacy: .public)")
    })
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
        // Everything past the fast path — the same-key join, the one-pipeline invariant
        // and the watchdog ceiling — belongs to the slot.
        return await slot.run(key: request.cacheKey) { [weak self] in
            await self?.runPipeline(request) ?? nil
        }
    }

    /// Cancellation stops the pipeline from STARTING an expensive stage. It never
    /// discards a stage that already finished.
    ///
    /// That asymmetry is the rule, and it is load-bearing in both directions. Two review
    /// passes killed an earlier version of this that checked after the render and after
    /// acceptance instead: the ceiling is 20 s and the belts are 4 s and 6 s, so a
    /// pipeline still alive at the ceiling has cleared both by definition and can only be
    /// in the tail — meaning a late check fires exactly when the raster is already in
    /// hand. It would have saved a 90×60 downsample and one draw, and thrown away ten
    /// seconds of style load and SDK render plus the cache write. The spec pins the other
    /// direction outright (§step 7: the write is "not guarded on cancellation — an
    /// accepted raster is worth keeping"), and with no negative cache the next request
    /// would have paid the whole pipeline again. The old abandoning watchdog got this
    /// right by accident: it let the pipeline finish and warm the cache.
    private func cancelledBeforeStarting(_ step: String) -> Bool {
        guard Task.isCancelled else { return false }
        Self.log.notice("share-map reject: cancelled before \(step, privacy: .public)")
        return true
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

        guard !cancelledBeforeStarting("the style load") else { return nil }
        guard await loadStyle(request.style.mapboxStyle, into: snapshotter) else { return nil }
        // Rejected read 1 of 2: a style/source error surfaced during the load.
        guard !errorFlags.rejected else {
            Self.log.notice("share-map reject: style/source loading error")
            return nil
        }
        // The only cancellation gate in the pipeline, and it is here because this is the
        // last point where stopping saves more than it destroys: everything paid for so
        // far is one style load, and everything ahead is the camera fit (an unbounded
        // synchronous main-actor walk of every route coordinate) plus the ≤6 s render.
        // Past the render there is no gate at all — see `cancelledBeforeStarting`.
        guard !cancelledBeforeStarting("the camera fit and render") else { return nil }
        guard fitCamera(snapshotter, to: request) else {
            Self.log.notice("share-map reject: degenerate camera fit")
            return nil
        }
        // Rejected read 2 of 2 sits inside renderMapRasterWithChrome, after the render resolves.
        guard let (raster, runs) = await renderMapRasterWithChrome(snapshotter, request: request, flags: errorFlags)
        else {
            Self.log.notice("share-map reject: render failed, timed out, mid-render error, or no captured route")
            return nil
        }
        // From here the pipeline runs to completion even when cancelled. It holds no
        // Snapshotter past this line (`renderMapRasterWithChrome` releases it on the main
        // actor before returning), so finishing costs the slot a few hundred ms of bounded
        // CPU and disk and buys a warm cache entry for the next request.
        guard await passesAcceptance(raster, key: request.cacheKey) else {
            Self.log.notice("share-map reject: raster failed the non-blank interior check")
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
            Self.log.notice("share-map reject: no strokeable route path at composite")
            return nil
        }

        // Not cancellation-gated, per the spec: "only accepted rasters; not guarded on
        // cancellation — an accepted raster is worth keeping" (§step 7).
        await persist(composited, key: request.cacheKey)
        Self.log.notice("share-map accepted and cached")
        return composited
    }

    /// Style load with its OWN resolve-once latch — a `MapStyleReconciler` completion can
    /// fire synchronously, and a double resume is a crash — raced against a 4 s belt
    /// (the Home-gate shape). Never also touches `styleJSON`/`styleURI`: a second load
    /// parks in `pendingCompletions` and can hang.
    private func loadStyle(_ style: MapboxMaps.MapStyle, into snapshotter: Snapshotter) async -> Bool {
        let latch = ResolveOnceLatch<StyleLoadOutcome>()
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<StyleLoadOutcome, Never>) in
                latch.attach(cont)
                snapshotter.load(mapStyle: style) { @Sendable error in
                    latch.resolve(error == nil ? .loaded : .failed)   // non-nil load error → reject
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { latch.resolve(.timedOut) }
            }
        } onCancel: {
            // Reversal of plan erratum (a): the watchdog now cancels rather than
            // abandoning, and without this the cancel would sit behind the 4 s belt with
            // the slot still held. Nothing to tear down here — a parked `load` completion
            // is harmless once the snapshotter is released.
            latch.resolve(.cancelled)
        }
        // Each arm logs its own reason. A nil from this pipeline is invisible in the UI by
        // design, so a reject that cannot be told apart from a hang costs a field
        // diagnosis — which is why `.cancelled` is a case of its own rather than folded
        // into `.failed`.
        switch outcome {
        case .loaded:
            return true
        case .failed:
            Self.log.notice("share-map reject: style load returned an error")
            return false
        case .cancelled:
            Self.log.notice("share-map reject: style load cancelled by the slot watchdog")
            return false
        // Belt timeout: the completion may be parked while the style actually loaded —
        // consult `isStyleLoaded` before rejecting (spec step 3). Legal here: this method
        // is back on the main actor after the await.
        case .timedOut:
            let loaded = snapshotter.isStyleLoaded
            if !loaded { Self.log.notice("share-map reject: style load timed out at the 4 s belt") }
            return loaded
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
        // Load-bearing for the cancellation arm below, not decoration. `onCancel` resolves
        // the same latch `store` feeds, and the only thing keeping it from resolving
        // BEFORE `store` — a permanent suspend — is that an already-cancelled `onCancel`
        // runs synchronously on the cancelling thread, that thread is main because this
        // method is main-actor, and the `DispatchQueue.main.async` hop therefore cannot be
        // dequeued until the synchronous store-then-start below has finished. Make this
        // method `nonisolated` and that chain breaks silently.
        MainActor.assertIsolated()
        let box = SnapshotBox()
        let raster: UIImage? = await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
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
        } onCancel: {
            // The 6 s belt's teardown, run early — same two calls in the same
            // cancel-before-resolve order. Hopped to main for two reasons: `Snapshotter.cancel()`
            // is main-thread-only and `onCancel` runs on whichever thread cancelled the task,
            // and the hop puts this strictly after the synchronous store-then-start above.
            // Without that ordering an already-cancelled task would resolve the latch before
            // `store` handed it a continuation — the wedge SnapshotBox.finish asserts on.
            DispatchQueue.main.async {
                box.snapshotterIfUnfinished()?.cancel()
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
                Self.log.notice("share-map acceptance cells (stddev, threshold \(threshold)): \(summary, privacy: .public)")
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
