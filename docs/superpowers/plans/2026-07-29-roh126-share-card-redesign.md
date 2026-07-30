# ROH-126 Shareable Ride Card Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Revision 2** — after adversarial plan review (skeptic + architecture, both REVISE). All
their must-change items are folded in; the concurrency shapes in Task 10 are the
reviewed, compile-checked ones.

**Goal:** Rebuild the shareable post-ride PNG so the route sits on a real map raster (rider's map style) with nothing covering the map, distance and stats in a readout band below, and a polyline fallback that ships instantly and upgrades in place.

**Architecture:** Pure, package-tested kernels in AuraKit + an app-target `ShareMapSnapshotter` behind a `ShareMapRasterProviding` seam (single app-lifetime instance, single-flight), a redesigned `ShareCardView`, and a fallback-first upgrade-in-place flow in `RideSummaryView`.

**Tech Stack:** SwiftUI, MapboxMaps v11 `Snapshotter` (`load(mapStyle:)`, capture-only overlay), CoreGraphics, SwiftPM tests (`swift test --no-parallel`), XcodeGen.

**The spec is normative:** `docs/superpowers/specs/2026-07-29-roh126-share-card-redesign-design.md` (rev 4). **Two plan errata against the spec, decided during plan review** (record in the PR): (a) the spec's `withTaskCancellationHandler`/`onCancel` provision is dropped — the pipeline task is coordinator-owned and nothing ever cancels it, so boundedness comes solely from the timeout arms; (b) "a caller's cancellation abandons only that caller's await" is weakened — awaiting a non-throwing `Task.value` is not a cancellation point, so a dismissed summary's `.task` stays suspended until the pipeline finishes (≤ ~10 s); harmless because the caller re-checks `Task.isCancelled` after the await. (c) the spec's budget table says context row 14.3 / total 176.6; the SF caption line box actually measures 16.0+, so the landed test uses a 16.5 ceiling and the measured total is 178.8 — still ≤ 182.

**Build/test commands:**
- Package: `cd AuraCore && swift test --no-parallel` (filter: `--filter <TestClass>`)
- App: `cd Aura && xcodegen generate && xcodebuild build -project Aura.xcodeproj -scheme Aura -configuration Debug -destination "id=$UDID" -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO -quiet` (`UDID` = booted iPhone 17 simulator; DerivedData pre-warmed)
- Lint: `scripts/lint.sh` (strict; budget for `function_body_length` 50 and `line_length` 140 — split the Task 10 pipeline into small private helpers from the start)

---

## File structure

Same as before (AuraKit: `ShareCardLayout`, `ShareRouteGeometry`, `ShareCameraValidation`, `ShareRasterAcceptance`, `ShareMapRequest`, `ShareRoutePath` under `AuraCore/Sources/AuraKit/Sharing/`; app: `ShareMapRasterProviding.swift`, `ShareMapSnapshotter.swift`, `ShareCardFileStore.swift` under `Aura/Sources/Ride/ShareCard/`, plus modifications to `ShareCardView`, `RideCardRenderer`, `RideSummaryView`, `StatPair`, `AuraTheme` (one UIColor), `AuraApp`, `RideHUDView`, `NavigateHUDView`).

**Injection note (deliberate divergence from spec, decided at review):** environment
injection (`@Observable ShareMapProviderBox` + `@Environment(ShareMapProviderBox.self)`)
instead of constructor injection. Trade: a future un-injected host crashes at runtime
instead of failing to compile; benefit: no parameter plumbing through two routers, and
both current sites (push + History sheet) verifiably inherit the root environment.

---

### Task 1: `ShareCardLayout` + CoreText-measured budget test

**Files:** create `AuraCore/Sources/AuraKit/Sharing/ShareCardLayout.swift`, `AuraCore/Tests/AuraKitTests/ShareCardLayoutTests.swift`; copy `Aura/Resources/Fonts/SairaCondensed-Bold.ttf` + `SairaCondensed-SemiBold.ttf` → `AuraCore/Tests/AuraKitTests/Resources/`; modify `AuraCore/Package.swift` (add the two TTFs as `.copy` test resources).

- [ ] **Step 1: Failing test.** As in rev 1 of this plan, with two corrections from review:
  - `contextCeiling: CGFloat = 16.5` (SF caption at Large is a 16.0 pt line box, not 14.3 — the budget still fits: ≈178.3 ≤ 182).
  - Add a font-sync test so the test-resource TTF can't drift from the app's:

```swift
func testFontResourceMatchesAppFont() throws {
    // Repo-relative from this source file: AuraCore/Tests/AuraKitTests/ → repo root.
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    for name in ["SairaCondensed-Bold", "SairaCondensed-SemiBold"] {
        let app = try Data(contentsOf: repoRoot.appending(path: "Aura/Resources/Fonts/\(name).ttf"))
        let ours = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "ttf")))
        XCTAssertEqual(app, ours, "\(name).ttf drifted from the app copy — re-copy it")
    }
}
```

  Keep `testGeometryInvariants`, `testBandBudgetFitsWithMeasuredSairaLineBoxes` (measured expectations: hero box ≈ 75.55, stats ≈ 26.76, ratio 1.574 ± 0.01 — review re-measured and confirmed), `testNoElevationVariantFits`.
- [ ] **Step 2:** `swift test --no-parallel --filter ShareCardLayoutTests` → FAIL (type missing).
- [ ] **Step 3: Implement `ShareCardLayout`** exactly as rev 1 of this plan (constants: card 360×450, map field 360×240, scale 3, band 210/20/12/16, gaps 4/8, hero 48, unit 18, stats value 17, stats label 13, wordmark 16, sparkline 40, casing 8, stroke 5, chrome strip 36, camera padding top/sides 24 bottom 40).
- [ ] **Step 4:** PASS. **Step 5: Commit.**

---

### Task 2: `ShareRouteGeometry`

**Files:** create `AuraCore/Sources/AuraKit/Sharing/ShareRouteGeometry.swift`, `AuraCore/Tests/AuraKitTests/ShareRouteGeometryTests.swift`.

- [ ] **Step 1: Failing tests.** As rev 1 **except** (review findings — the old fixture made both decimation assertions vacuous):
  - Decimation fixture must be a route whose lat/lon extremes are **interior** — e.g. a sine loop: `lat = 40.44 + 0.01 * sin(Double(i) / 300)`, `lon = -79.99 + 0.01 * cos(Double(i) / 300)` for 5000 points. Assert `count <= ShareRouteGeometry.maxPointsPerSegment` **and** all four extremes preserved.
  - Distinctness is numeric, not string-based (a 3-hour ride would pay ~20k Double→String conversions on a hot path): quantized `(Int, Int)` pairs at 1e5.
- [ ] **Step 2:** FAIL.
- [ ] **Step 3: Implement.** As rev 1 with these corrections:
  - `fnv1a` stays `internal` — both new callers are in AuraKit; no access widening.
  - Distinct check: `Set(all.map { Q($0) }).count >= 2` where `Q(c) = (Int((c.latitude*1e5).rounded()), Int((c.longitude*1e5).rounded()))` (make it a small private function; contentHash hashes the same quantized ints — build the hash by feeding bytes incrementally, not one giant `+=` string).
  - Decimation cap must hold **including** forced extremes: build the stride index set, add the 4 extreme indices, and if `count > maxPointsPerSegment` remove non-extreme stride indices from the middle until it fits (or reserve 4 slots up front: stride to `maxPointsPerSegment - 4`).
- [ ] **Step 4:** PASS + full package suite once. **Step 5: Commit.**

---

### Task 3: `ShareCameraValidation`

As rev 1 (predicate over `Double?` lat/lon/zoom; nil/NaN/∞ → nil; guard-then-clamp zoom ≤ 16), **plus one normative usage rule recorded in the file's doc comment and enforced in Task 10:** the predicate is a *gate*, not the camera's constructor — the caller must mutate the **returned `CameraOptions`** (replace `zoom` only) and pass the whole thing to `setCamera(to:)`, because the returned `padding` is what keeps the route out of the SDK chrome band (the ToS invariant; discarding it re-fits the route into the full 360×240 and puts ~4 pt of casing over the Mapbox logo).

- [ ] Steps: failing test → FAIL → implement → PASS → commit.

---

### Task 4: `ShareRasterAcceptance`

As rev 1 with review corrections:

- [ ] **Step 1: Failing tests.** Fixtures: flat → reject; flat + bright rows *inside* the excluded strip → reject; flat + bright rows *just above* the strip → reject is NOT required (that's real signal) but assert the strip boundary is honored both ways; textured interior (seeded noise) → accept; texture in one quadrant only → reject. Also test a `bytesPerRow`-mismatch guard rejection.
- [ ] **Step 3: Implement** with:
  - `public static let varianceThreshold: Double = 4.0` and `texturedCellFraction: Double = 0.5` — **`let`, not `var`** (Swift 6 language mode forbids nonisolated global mutable state); `accepts(...)` also takes them as parameters with these defaults so tuning and tests don't need globals.
  - Signature documents the unit contract: `excludedBottomRows` is **rows of the downsampled buffer**.
- [ ] PASS → commit.
- [ ] **Follow-up marker:** after Task 14 exports real rasters of the three styles, land cropped grayscale fixtures + threshold assertions in this test file (tracked as Task 14's last step — the seeded-noise fixtures cannot validate the threshold's real discriminating power).

---

### Task 5: `ShareMapRequest`

As rev 1 (FNV-1a key over rideID | route hash | style identity | composite version | size@scale; style identity from the `AuraKit.MapStyle` case). Keep the composed-identity string under 140 chars per line when implementing (lint).

- [ ] Steps: failing tests (filename-safety, stability, sensitivity to style/route/version) → FAIL → implement → PASS → commit.

---

### Task 6: `ShareRoutePath`

As rev 1 (`static func path(runs: [[CGPoint]]) -> CGPath?`; nil when no run has ≥ 2 points; subpath per run; verify no cross-run connection by counting `.moveToPoint` elements).

- [ ] Steps: failing tests → FAIL → implement → PASS → commit.

---

### Task 7: `StatPair` label color + casing UIColor

**Files:** modify `Aura/Sources/Theme/StatPair.swift`, `Aura/Sources/Theme/AuraTheme.swift`.

- [ ] Add `var labelColor: Color? = nil` to `StatPair` (label uses `labelColor ?? AuraTheme.textSecondary`).
- [ ] Add to `AuraTheme`, next to `routeUIColor`: `static let routeCasingUIColor = UIColor(red: AuraPalette.nearBlack.red, green: AuraPalette.nearBlack.green, blue: AuraPalette.nearBlack.blue, alpha: 1)` (mirror `routeUIColor`'s exact construction — `AuraPalette.nearBlack` is an `RGBColor` value, not a strokeable color).
- [ ] Build → succeeds. Commit.

---

### Task 8: `ShareCardView` redesign

**Files:** modify `Aura/Sources/Ride/ShareCard/ShareCardView.swift` only.

- [ ] **Step 1: Implement per spec §Layout**, rev 1's sketch with these review corrections:
  - `let mapImage: UIImage?` gets **no default in spirit but the declaration order keeps `RideCardRenderer` compiling** — actually: give it a default of `nil` so this task builds green (`RideCardRenderer.swift:17` still calls `ShareCardView(content:)` until Task 9); remove nothing else.
  - `contextLine` is a `String` computed property today — wrap it: `Text(contextLine).font(...).tracking(1.5).lineLimit(1).foregroundStyle(scrimText)`.
  - **Moving time**: `RideStatsFormatter.minutes` returns `"42 min"`, not `"42"`. The cockpit-numeral rule needs the number alone in Saira. Decision (spec non-goal preserved — `ShareCardContent` untouched): the view derives `movingValue = content.movingTime.hasSuffix(" min") ? String(content.movingTime.dropLast(4)) : content.movingTime`, with a comment naming the formatter contract. Stats row renders `movingValue` in Saira + label `" MIN MOVING"`, then `content.climbedValue` + `" \(climbedUnit) CLIMBED"` — never `content.movingTime` raw (which would render "42 min MIN MOVING"). The worst-case width string is unchanged (`480` + `MIN MOVING · ` + `12000` + `FT CLIMBED` + wordmark ≈ 324 pt vs 320 → `minimumScaleFactor(0.85)` absorbs it).
  - Literals that stay literal (theme idiom, not layout budget): `RouteThumbnail` inset `AuraTheme.Spacing.lg`, `lineWidth: 3`, `tracking(1.5)/(4)`, sparkline fill opacity `0.18`, `minimumScaleFactor(0.85)`. Everything that participates in the **vertical budget** comes from `ShareCardLayout`.
  - No-route variant: unchanged structure; pass `labelColor: scrimText` to its `StatPair`s.
  - Replace the stale header comment (lines 6–10) — the card now takes a pre-rendered Snapshotter raster; a live Map still can't render in `ImageRenderer`.
  - Previews: map variant (inline `UIGraphicsImageRenderer` gradient fixture at exactly 360×240 @3x), polyline fallback, no-route, route-without-elevation, long destination, worst-case stats string, metric + imperial.
- [ ] **Step 2:** Build → succeeds (default `nil` keeps the old call site alive). **Step 3: Commit.**

---

### Task 9: `ShareCardFileStore` + `RideCardRenderer`

**Files:** create `Aura/Sources/Ride/ShareCard/ShareCardFileStore.swift`; modify `Aura/Sources/Ride/ShareCard/RideCardRenderer.swift`.

- [ ] File store as rev 1 (`tmp/ShareCard/<rideID>/<presentationUUID>/<generation>/Aura ride.png`; `sweepOtherRides()` off-main, other rides only, > 1 h old) — declared **`nonisolated struct ShareCardFileStore: Sendable`** (default MainActor isolation would otherwise make the off-main sweep a compile error, and only once a `@Sendable` closure touches it).
- [ ] **Remove `ShareCardView.mapImage`'s `= nil` default in this task** (it existed only so Task 8 built before this task updated the call sites; leaving it ships a permanent seam where a forgotten argument silently yields the fallback card).
- [ ] `RideCardRenderer.make(_ content:, mapImage: UIImage?, title: String, writeTo url: URL) async -> RideShareImage?`:
  - `ImageRenderer` on main; then `Task.detached` for **create-directory-then-encode-then-atomic-write** (a write into a missing directory throws; a failed generation-0 write means Share stays disabled, so directory creation is mandatory, not defensive).
  - `RideShareImage` gains `let title: String`.
  - Update the internal `ShareCardView(content:)` call to pass `mapImage`.
- [ ] Build → succeeds (RideSummaryView still calls the *old* signature — update that call site minimally in this task: pass `mapImage: nil`, a computed title, and `store.url(generation: 0)` with a locally created store; Task 11 restructures the flow properly). Commit.

---

### Task 10: `ShareMapSnapshotter` — seam, box, pipeline, single-flight

**Files:** create `Aura/Sources/Ride/ShareCard/ShareMapRasterProviding.swift`, `Aura/Sources/Ride/ShareCard/ShareMapSnapshotter.swift`.

The concurrency shapes below are **normative and were compile-review-corrected twice**
(the second delta review reproduced a livelock and two compile breaks in the first
correction); do not improvise around them. Background: the SDK's `start` completion and
overlay handler are non-`@Sendable` closure types invoked **off-main** whenever the
attribution text falls to `.none` — the *likely* branch at our 360 pt width — and this
repo's `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor` makes a naive closure literal compile
clean while racing. Write all three SDK closures (overlay, completion, and the style
load's `(Error?) -> Void`) **explicitly `@Sendable`**, and keep all callback-touched
state in lock-guarded nonisolated boxes.

**Systemic rule (applies to every new app-target declaration in Tasks 9–12):** under
default MainActor isolation, *every* new type/function is `@MainActor` unless it says
otherwise, and the compiler only complains once a `@Sendable` closure touches it.
Anything used off the main actor must be **explicitly `nonisolated`**: `SnapshotBox`,
the error-flags box, `projectedRuns` (`nonisolated static func`), and Task 9's
`ShareCardFileStore` (`nonisolated struct ShareCardFileStore: Sendable`). Off-main code
must not read `@MainActor` statics either — hoist `AuraTheme.routeUIColor.cgColor` /
`routeCasingUIColor.cgColor` into locals on the main actor before any detached hop
(today that's only a warning, so a green build will hide it).

- [ ] **Step 1: Seam + box** (as rev 1: `ShareMapRasterProviding` protocol; `@Observable @MainActor ShareMapProviderBox`).

- [ ] **Step 2: The snapshot box** — replaces rev 1's `@MainActor SnapshotAttempt`, which was unbuildable (`withLock` takes a `@Sendable` body that cannot touch main-actor state) and raced:

```swift
/// Everything the SDK's off-main callbacks touch, behind one lock. `nonisolated` is
/// REQUIRED: without it, default MainActor isolation infers `@MainActor` onto this
/// class (the `Sendable` conformance does not opt out) and Step 4.7 fails to compile.
/// The completion/overlay handler run on Mapbox's compositor thread when the
/// attribution label falls to `.none` (the common case at card width).
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
```

  (`withLockUnchecked` because the state holds non-Sendable `Snapshotter`/continuation;
  the box's discipline — release only on main, resume-once — is what makes it sound.
  `CGPoint`/`UIImage` are Sendable.)

- [ ] **Step 3: Single-flight coordinator** — pinned shape (rev 1's "while inFlight != nil { await ... }" admitted a main-actor spin):

```swift
@MainActor final class ShareMapSnapshotter: ShareMapRasterProviding {
    private var inFlight: (key: String, task: Task<UIImage?, Never>)?
    private let cache = TerrainSnapshotDiskCache(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "ShareCardSnapshots"))   // its own directory — sharing Home's
                                                      // TerrainSnapshots would let two prune
                                                      // budgets evict each other's files

    func raster(for request: ShareMapRequest) async -> UIImage? {
        if let inFlight, inFlight.key == request.cacheKey { return await inFlight.task.value }
        while let current = inFlight { _ = await current.task.value }   // suspends, no spin
        // No await between the loop exit and this assignment (single-pipeline invariant).
        let task = Task { [weak self] in await self?.runPipelineReleasingSlot(request) ?? nil }
        inFlight = (request.cacheKey, task)
        return await task.value
    }

    /// Owns the in-flight slot's lifetime: cleared on EVERY exit, including the
    /// cache-hit and reject early returns. Do not move this into runPipeline —
    /// runPipeline is nothing but early returns, and a "clear at the end" only runs
    /// on the full-success path: every failure (offline reject, the headline error
    /// path) would leave a completed task in the slot forever, wedging same-key
    /// retries and LIVELOCKING different-key waiters' while-loop on the main actor
    /// (reproduced in plan delta-review). This is the spec's normative `defer`.
    private func runPipelineReleasingSlot(_ request: ShareMapRequest) async -> UIImage? {
        defer { if inFlight?.key == request.cacheKey { inFlight = nil } }
        return await runPipeline(request)
    }
}
```

  The `defer` in the wrapper is safe (unlike a `defer` in `raster` itself, which was the
  rev-1 bug): the slot is cleared exactly when the pipeline task finishes, and same-key
  callers each `await task.value` independently. Note: `Task.value` of a non-throwing
  task is **not** a cancellation point (plan erratum b). Also record: **no negative
  cache** — a rejected pipeline re-runs in full on the next request (e.g. a History
  open after an offline reject re-runs the ≤10 s pipeline with the hint up); this is
  the spec's accepted cost, not a bug, and device verification should expect it.

- [ ] **Step 4: The pipeline** (`private func runPipeline(_ request: ShareMapRequest) async -> UIImage?` on the MainActor, split into `< 50`-line helpers for lint). Order, with the review-corrected lines:
  1. `MainActor.assertIsolated()`.
  2. Cache read: `if let data = cache.read(request.cacheKey) { return UIImage(data: data, scale: request.scale) }` — the cache stores the **composited** image; hits return as-is.
  3. Build `Snapshotter(options: MapSnapshotOptions(size: request.size, pixelRatio: request.scale, glyphsRasterizationOptions: GlyphsRasterizationOptions(rasterizationMode: .ideographsRasterizedLocally)))`.
  4. Error observer **before** the load, token cancelled in a `defer`. Handler is `@Sendable`, writes into `private nonisolated final class MapLoadErrorFlags: @unchecked Sendable` — one lock guarding BOTH the `rejected` flag and the `.tile` counter (`initialState:` is fine here, the state is all-Sendable): `.style`/`.source` → set `rejected`; `.tile` → count only (log; edge tiles 404 routinely; variance is the partial-tile gate). The `rejected` flag is read at two points: after the style load, and after the render completes (a style error surfacing mid-render discards the raster — conservative and cheap).
  5. Style load with its **own** resolve-once latch (a `MapStyleReconciler` completion can fire synchronously; double resume = crash): `snapshotter.load(mapStyle: request.style.mapboxStyle /* via MapStyle+Mapbox */)` — the completion is `((Error?) -> Void)?`; write it `@Sendable`; a **non-nil error → reject**. Raced against a 4 s belt (`DispatchQueue.main.asyncAfter` arm, Home-gate shape). **Never also touch `styleJSON`/`styleURI`.** On belt timeout consult `snapshotter.isStyleLoaded` before rejecting.
  6. Camera (strictly after style): `var cam = snapshotter.camera(for: coords, padding: UIEdgeInsets(top: 24, left: 24, bottom: 40, right: 24), bearing: 0, pitch: 0)`; gate via `ShareCameraValidation.validated(latitude: cam.center?.latitude, longitude: cam.center?.longitude, zoom: cam.zoom)`; on pass, `cam.zoom = validated.zoom` and `snapshotter.setCamera(to: cam)` — **mutate the returned options; do not rebuild them** (the returned `padding` is the sole enforcement of route-clear-of-chrome).
  7. Render:

```swift
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
guard !errorFlags.rejected, let raster else { return nil }
let runs = box.runs
guard runs.contains(where: { $0.count >= 2 }) else { return nil }   // no route captured →
                                                                    // never ship/cache a routeless map card
```

  8. Acceptance, with the strip conversion **pinned** (rev 1 left it in an undefined variable): downsample the raster to a grayscale buffer of exactly `90×60` (`width = 90, height = 60`, i.e. size/4 in points) drawn via a `CGContext` created with **`bytesPerRow: 90`** explicitly (CG's default alignment padding would fail the `count == width*height` guard and silently reject every raster); `excludedBottomRows = Int((ShareCardLayout.mapChromeStripHeight / ShareCardLayout.mapFieldSize.height * 60).rounded(.up))` → **9**. Run `ShareRasterAcceptance.accepts` off-main (`Task.detached`).
  9. Composite (off-main is fine — `UIGraphicsImageRenderer` bitmap drawing is thread-safe): `let format = UIGraphicsImageRendererFormat(); format.scale = request.scale` (**no `init(scale:)` exists**); `UIGraphicsImageRenderer(size: request.size, format: format)`; draw the raster with **`raster.draw(in: CGRect(origin: .zero, size: request.size))`** (not `context.cgContext.draw` — that flips the map upside down under a correctly-oriented route); stroke `ShareRoutePath.path(runs:)` — casing `AuraTheme.routeCasingUIColor` width 8, then mint `AuraTheme.routeUIColor` width 5, round caps/joins. If `path(runs:)` is nil → return nil (before any cache write).
  10. Encode + `cache.write` + `cache.prune(toMaxBytes: 24 * 1024 * 1024)` off-main; return the composited image.

- [ ] **Step 5:** Build → succeeds; `scripts/lint.sh` → clean (helpers under 50 lines; no line over 140).
- [ ] **Step 6: Commit.**

---

### Task 11: `RideSummaryView` flow + hint + title

**Files:** modify `Aura/Sources/Ride/RideSummaryView.swift`.

- [ ] **Step 1:** Per spec §Share flow with review corrections:
  - `@Environment(ShareMapProviderBox.self) private var shareMap`; `@State private var isUpgrading = false`; `@State private var showHint = false`.
  - `.task` (keep the existing `guard ride.stats != nil, shareImage == nil` — both presentation paths get fresh `@State`, verified at review, so re-entry semantics are unchanged):
    1. Existing `Task.yield()`.
    2. `let store = ShareCardFileStore(rideID: ride.id)`; `store.sweepOtherRides()`.
    3. `let title = "Aura ride · \(content.distanceValue) \(content.distanceUnit) · \(content.dateText)"`.
    4. Fallback: `shareImage = await RideCardRenderer.make(content, mapImage: nil, title: title, writeTo: store.url(generation: 0))`.
    5. `guard let request = ShareMapRequest(rideID: ride.id, segments: content.routeSegments, style: settings.mapStyle) else { return }` — **`content.routeSegments`**, the one source of truth.
    6. **Both paths wait out the entrance window before requesting** (review: rev 1 gave the delay to the path without a transition and withheld it from the path with one): `try? await Task.sleep(for: .seconds(0.8))`; `guard !Task.isCancelled else { return }`. (Ride-end: the prefetch fired at +0.7 s is already in flight; this request dedups onto it. History: this is the entrance-animation courtesy delay.)
    7. `isUpgrading = true`, then in the same task (NOT `async let` — an `async let`
       child is nonisolated and cannot touch `@State`; compile-verified break):

       ```swift
       let hint = Task {                     // inherits MainActor; @State access legal
           try? await Task.sleep(for: .seconds(0.3))
           if isUpgrading { showHint = true }
       }
       ```

       The delay starts **from the `isUpgrading = true` transition**; the `if isUpgrading`
       re-check stays (prevents a late flash after step 10 clears the flags).
    8. `let raster = await shareMap.provider.raster(for: request)`, then `hint.cancel()`.
    9. `if let raster, !Task.isCancelled, let upgraded = await RideCardRenderer.make(content, mapImage: raster, title: title, writeTo: store.url(generation: 1)) { shareImage = upgraded }` — never assign nil over a working fallback.
    10. `isUpgrading = false; showHint = false` — **both cleared, always** (rev 1 left the spinner on screen forever).
  - Hint view under Share: `if showHint { HStack(spacing: AuraTheme.Spacing.xs) { ProgressView(); Text("Adding your map…") }.font(.caption).foregroundStyle(AuraTheme.secondaryText(contrast)) }`.
  - **`SharePreview(shareImage.title, image: shareImage.preview)`** — the title is wired here (rev 1 added the field and never used it).
- [ ] **Step 2:** Build → succeeds. **Step 3: Commit** (note: summary screen crashes at runtime until Task 12 injects the box — Tasks 11+12 land in adjacent commits; do not pause between them).

---

### Task 12: App wiring — injection + ride-end prefetch

**Files:** modify `Aura/Sources/AuraApp.swift`, `Aura/Sources/Ride/RideHUDView.swift`, `Aura/Sources/Ride/NavigateHUDView.swift`.

- [ ] `AuraApp`: `@State private var shareMapBox = ShareMapProviderBox(provider: ShareMapSnapshotter())`; `.environment(shareMapBox)` at the WindowGroup root next to the existing injections.
- [ ] Both HUD call sites (`RideHUDView.swift:200`, `NavigateHUDView.swift:244`), immediately before `router.showRideSummary(...)`:

```swift
// Prefetch the share-map raster. Detached + delayed: request construction walks the
// whole track (ShareRouteGeometry.prepare), and the push transition starts on the next
// line — neither belongs on this frame. The summary's own request (t≈0.8s) dedups
// onto this via the shared provider instance.
let provider = shareMapBox.provider
let segments = ride.segments.map { $0.points.map(\.coordinate) }.filter { $0.count > 1 }
let style = settings.mapStyle
let rideID = ride.id
Task.detached(priority: .utility) {
    try? await Task.sleep(for: .seconds(0.7))
    guard let request = ShareMapRequest(rideID: rideID, segments: segments, style: style) else { return }
    _ = await provider.raster(for: request)
}
```

  (`segments` here uses the same map+filter expression as `ShareCardContent.routeSegments`, so the cache keys match; a comment must say the two must stay in lockstep. Add `@Environment(ShareMapProviderBox.self)` to both HUDs.)
- [ ] Build + `scripts/lint.sh` → clean. Commit.

---

### Task 13: Full gate

- [ ] `cd AuraCore && swift test --no-parallel` → all pass; app build → succeeds; `scripts/lint.sh` → clean; commit anything outstanding.

---

### Task 14: Device/simulator verification (spec §Testing — all items)

Setup as rev 1 (install + `simctl launch` with the golden-ride args; drive via the iOS-simulator control tool).

- [ ] Fallback card exists immediately (pull generation 0 from the app container); map card replaces it (generation 1); inspect full-size and at ~130 pt.
- [ ] Tap Share **before** the upgrade lands; complete a share to Photos and Messages; confirm the presented sheet survives the swap. **Contingency (owner: implementer, this task):** if the sheet dismisses or its payload changes, implement the swap latch — replace `ShareLink` with a Button presenting `UIActivityViewController` via a representable so presentation state is knowable, and defer the swap while presented; re-verify.
- [ ] Second open from History → cache hit: no re-render, PNG not zoom-cropped (`UIImage(data:scale:3)` path), route not double-stroked (composited-cache path).
- [ ] All three styles; casing keeps the route legible on `standard`; route never enters the bottom 36 pt chrome band (visual check with a route whose southernmost edge is data-driven, e.g. the golden ride).
- [ ] Offline `auraTerrain` (device airplane mode, or host NLC "100% Loss" against the simulator): polyline fallback renders, never a blank map.
- [ ] Slow network (NLC "Very Bad Network"): partial raster rejected → fallback.
- [ ] **Paused multi-segment ride — manual procedure** (the `-auraSimulatedRide paused` fixture hook does not exist; `SimulatedRideSupport` ignores the fixture name): during golden-ride playback, tap Pause in the HUD, wait ~10 s, Resume, then End. Verify the share card strokes two separate runs with no line across the gap.
- [ ] No-route variant on device (end a ride with no movement, or a zero-track History ride).
- [ ] Entrance animation drops no frames (the 0.8 s request delay + 0.7 s detached prefetch keep the transition window clear); record time-to-upgrade for the PR.
- [ ] **Export the three style rasters** (pull the cached `ShareCardSnapshots` PNGs) → land cropped grayscale fixtures in `ShareRasterAcceptanceTests` with threshold assertions (closes Task 4's follow-up marker).
- [ ] Screenshots (map card, fallback card, `.standard` card) for the PR.

---

### Task 15: Wrap-up

- [ ] Whole-branch review (repo pipeline step 6) on the most capable model; fix findings.
- [ ] PR to `main` (humanizer-passed body; screenshots + time-to-upgrade + the two plan errata); link ROH-126.
- [ ] Move ROH-126 to **In Review**, comment with the PR link; Rohun reviews.
