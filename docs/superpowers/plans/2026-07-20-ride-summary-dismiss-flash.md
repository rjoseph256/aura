# Ride-Summary Dismiss-Flash Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the ride HUD from flashing for ~0.5s when the ride-summary is dismissed, by making the summary a pushed `NavigationStack` route reached by collapsing the path to a single entry, instead of a `.sheet` hosted on the HUD.

**Architecture:** On ride finish, the HUD observes `coordinator.finishedRide` and calls `router.showRideSummary(ride, saveFailed:)`, which sets `path = RideSummaryRouting.collapsed(ride:saveFailed:)` = `[.rideSummary(payload)]` — collapsing the whole nav path so only Home sits beneath the summary. `RootView` renders `RideSummaryView` for that route (nav chrome hidden, swipe-back off). **Done** calls `router.popToRoot()`, a single-level pop straight to Home with nothing to flash. `HistoryView` keeps presenting `RideSummaryView` as its own sheet, unchanged.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`import Testing`), SwiftPM package `AuraCore` (contains `AppRoute` + the new routing helper + their tests) and the Xcode app target `Aura` (contains `AppRouter`, `RootView`, the HUDs, `RideSummaryView` — no test bundle, verified by build + device).

## Global Constraints

- Swift 6 strict concurrency; all touched types are `@MainActor` or `Sendable` as they already are.
- `AppRoute` is `public enum AppRoute: Sendable` with **hand-written** `Equatable`/`Hashable` that hash each case by payload **id**, never by content. The new case must follow this exactly (hash by `ride.id`).
- App target (`Aura/Sources/**`) has **no unit-test bundle** (established convention). Pure logic that needs a test goes in `AuraCore`; app-target SwiftUI wiring is verified by compiling the app scheme and by device verification. The path-collapse itself is therefore extracted into an AuraCore helper (Task 2) so its invariant IS unit-tested.
- **Build coupling:** the moment Task 1 adds `case rideSummary` to `AppRoute`, `RootView`'s `switch route` (`AuraApp.swift:90`, no `default`) is non-exhaustive, so **the `Aura` app target does not compile between Task 1 and Task 5**. That is expected. In that window only `swift test --package-path AuraCore` is meaningful; do **not** "fix" the switch with a bogus `default:` (it would defeat exhaustiveness checking) — Task 5 adds the real case.
- `swiftlint --strict` must pass locally before merge (local merges skip CI SwiftLint).
- Do **not** change `RideSessionCoordinator`, `NavigateHUDView+GroupCrew`, or the History sheet.
- Do **not** add any `onChange(of: groupSession?.phase)` auto-finish (would tear down a still-riding guest — ROH-81 class bug). The summary nav is triggered ONLY by the rider's own `coordinator.finishedRide`.
- Delegate Xcode/simulator builds to the `apple-platform-build-tools:builder` agent. **Other sessions are using simulators** — build compile-only against a *generic* simulator destination (does not boot a sim); never `simctl boot`/`erase` a simulator that may belong to another session.

---

### Task 1: `AppRoute.rideSummary` case + `RideSummaryPayload` (AuraCore, TDD)

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Navigation/AppRoute.swift`
- Test: `AuraCore/Tests/AuraCoreTests/AppRouteTests.swift`

**Interfaces:**
- Consumes: `Ride` (`AuraCore/Sources/AuraCore/Models/Ride.swift`, `public struct … Sendable`, `id: UUID`); `TrackPoint`/`Coordinate` (`AuraCore/Sources/AuraCore/Geo/`).
- Produces:
  - `public struct RideSummaryPayload: Sendable { public var ride: Ride; public var saveFailed: Bool; public init(ride: Ride, saveFailed: Bool) }`
  - `AppRoute.rideSummary(RideSummaryPayload)` — equal/hash by `ride.id` only.

- [ ] **Step 1: Write the failing tests**

Add to `AuraCore/Tests/AuraCoreTests/AppRouteTests.swift`. Add this `Ride` helper inside the `AppRouteTests` struct (next to the existing `place`/`route` helpers):

```swift
    private func ride(_ id: UUID = UUID(), trackCount: Int = 0) -> Ride {
        Ride(id: id, kind: .navigate, startedAt: Date(timeIntervalSince1970: 0),
             endedAt: Date(timeIntervalSince1970: 60),
             track: Array(repeating: TrackPoint(coordinate: Coordinate(latitude: 40.44,
                                                                       longitude: -79.99),
                                                elevation: nil,
                                                timestamp: Date(timeIntervalSince1970: 0)),
                          count: trackCount),
             stats: nil, routeId: nil, destinationPlaceId: nil)
    }
```

`TrackPoint`'s initializer is `TrackPoint(coordinate:elevation:timestamp:speedMetersPerSecond:)` (`speedMetersPerSecond` defaulted) and `Coordinate(latitude:longitude:)` — both in `AuraCore/Sources/AuraCore/Geo/`; `Ride.init` omits only the defaulted `destinationName`. The point's contents are irrelevant to route identity.

Then add these tests:

```swift
    @Test func rideSummaryEqualByRideIdIgnoringSaveFailedAndTrack() {
        let id = UUID()
        let a = AppRoute.rideSummary(RideSummaryPayload(ride: ride(id, trackCount: 2),
                                                        saveFailed: false))
        let b = AppRoute.rideSummary(RideSummaryPayload(ride: ride(id, trackCount: 5000),
                                                        saveFailed: true))
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test func rideSummaryDifferentRideIdsUnequal() {
        #expect(AppRoute.rideSummary(RideSummaryPayload(ride: ride(), saveFailed: false))
                != AppRoute.rideSummary(RideSummaryPayload(ride: ride(), saveFailed: false)))
    }

    @Test func rideSummaryDistinctFromOtherCases() {
        let r = AppRoute.rideSummary(RideSummaryPayload(ride: ride(), saveFailed: false))
        #expect(r != AppRoute.freeRide)
        #expect(r != AppRoute.history)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Ask the builder agent (or run locally): `swift test --package-path AuraCore --filter AppRouteTests`
Expected: FAIL to compile — `rideSummary` / `RideSummaryPayload` are undefined.

- [ ] **Step 3: Add the payload type and the case**

In `AuraCore/Sources/AuraCore/Navigation/AppRoute.swift`, add the case to the enum (after `.settings`):

```swift
    /// The finished-ride summary, pushed as a navigation destination (not a sheet) so that
    /// returning Home via `popToRoot()` animates summary → Home directly, with no ride HUD
    /// left in the stack to flash (ROH-85). Reached by collapsing the whole path to this single
    /// entry, so only Home sits beneath it.
    case rideSummary(RideSummaryPayload)
```

Add the payload type at the bottom of the file (top level):

```swift
/// Self-contained payload for `AppRoute.rideSummary`: the finished ride and whether it failed
/// to persist. Held by value so the summary renders after the producing coordinator/HUD is torn
/// down. `AppRoute` hashes/equates this case by `ride.id` ONLY (see the comment on `AppRoute`'s
/// `==`/`hash`); `saveFailed` is deliberately outside identity.
public struct RideSummaryPayload: Sendable {
    public var ride: Ride
    public var saveFailed: Bool
    public init(ride: Ride, saveFailed: Bool) {
        self.ride = ride
        self.saveFailed = saveFailed
    }
}
```

- [ ] **Step 4: Extend `Equatable` and `Hashable`**

In the same file, add to the hand-written `static func ==` (inside the `switch`, before `default`):

```swift
        case let (.rideSummary(a), .rideSummary(b)):
            // saveFailed deliberately excluded — identity is the ride, not its save outcome.
            return a.ride.id == b.ride.id
```

And to `func hash(into:)` (add a new case; `6` is taken by `.settings`, so use `7`) — mirror the identity comment so a future editor touching only `hash` sees it:

```swift
        case let .rideSummary(payload):
            // saveFailed deliberately excluded from identity — hash the ride only.
            hasher.combine(7)
            hasher.combine(payload.ride.id)
```

- [ ] **Step 5: Run the tests to verify they pass**

`swift test --package-path AuraCore --filter AppRouteTests`
Expected: PASS (all AppRouteTests, including the three new ones).

- [ ] **Step 6: Commit**

```bash
git add AuraCore/Sources/AuraCore/Navigation/AppRoute.swift AuraCore/Tests/AuraCoreTests/AppRouteTests.swift
git commit -m "feat(roh-85): add AppRoute.rideSummary route + payload (hash by ride.id)"
```

---

### Task 2: `RideSummaryRouting.collapsed` pure helper (AuraCore, TDD)

Extract the path-collapse — the highest-severity design decision (collapse to a single entry, NOT a top-swap that would leave a stale preview beneath) — into a pure, unit-tested AuraCore function so the invariant is guarded by a test rather than only by device inspection.

**Files:**
- Create: `AuraCore/Sources/AuraCore/Navigation/RideSummaryRouting.swift`
- Test: `AuraCore/Tests/AuraCoreTests/RideSummaryRoutingTests.swift`

**Interfaces:**
- Consumes: `Ride`, `RideSummaryPayload`, `AppRoute` (Task 1).
- Produces: `public enum RideSummaryRouting { public static func collapsed(ride: Ride, saveFailed: Bool) -> [AppRoute] }` returning exactly `[.rideSummary(RideSummaryPayload(ride:saveFailed:))]`.
- Consumed by: Task 4 (`AppRouter.showRideSummary` assigns `path = RideSummaryRouting.collapsed(...)`).

- [ ] **Step 1: Write the failing tests**

Create `AuraCore/Tests/AuraCoreTests/RideSummaryRoutingTests.swift`:

```swift
import Testing
import Foundation
import AuraCore

struct RideSummaryRoutingTests {
    private func ride(_ id: UUID = UUID()) -> Ride {
        Ride(id: id, kind: .freeRide, startedAt: Date(timeIntervalSince1970: 0),
             endedAt: Date(timeIntervalSince1970: 60), track: [], stats: nil,
             routeId: nil, destinationPlaceId: nil)
    }

    @Test func collapsedIsAlwaysExactlyTheSummaryEntry() {
        let result = RideSummaryRouting.collapsed(ride: ride(), saveFailed: false)
        #expect(result.count == 1)          // collapse, NOT a top-swap that keeps prior entries
        if case .rideSummary = result[0] {} else { Issue.record("expected .rideSummary at [0]") }
    }

    @Test func collapsedCarriesRideAndSaveFailed() {
        let id = UUID()
        let result = RideSummaryRouting.collapsed(ride: ride(id), saveFailed: true)
        guard case let .rideSummary(payload) = result.first else {
            Issue.record("expected .rideSummary"); return
        }
        #expect(payload.ride.id == id)
        #expect(payload.saveFailed == true)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

`swift test --package-path AuraCore --filter RideSummaryRoutingTests`
Expected: FAIL to compile — `RideSummaryRouting` undefined.

- [ ] **Step 3: Implement the helper**

Create `AuraCore/Sources/AuraCore/Navigation/RideSummaryRouting.swift`:

```swift
/// The navigation path that presents a finished-ride summary (ROH-85).
///
/// It COLLAPSES the whole stack to a single `.rideSummary` entry, deliberately NOT preserving
/// the HUD or any screen beneath it (e.g. the `.preview` that sits under a navigate ride). Only
/// Home remains beneath, so `popToRoot()` on Done is a single-level pop straight to Home with
/// nothing stale to flash. Every ride end already returns to Home, so discarding prior entries
/// matches existing behavior. Pure so the "single entry" invariant is unit-tested.
public enum RideSummaryRouting {
    public static func collapsed(ride: Ride, saveFailed: Bool) -> [AppRoute] {
        [.rideSummary(RideSummaryPayload(ride: ride, saveFailed: saveFailed))]
    }
}
```

- [ ] **Step 4: Run to verify it passes**

`swift test --package-path AuraCore --filter RideSummaryRoutingTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/Navigation/RideSummaryRouting.swift AuraCore/Tests/AuraCoreTests/RideSummaryRoutingTests.swift
git commit -m "feat(roh-85): pure RideSummaryRouting.collapsed helper (single-entry invariant)"
```

---

### Task 3: `RideSummaryView.onDone` hook (app target)

**Files:**
- Modify: `Aura/Sources/Ride/RideSummaryView.swift`

**Interfaces:**
- Produces: `RideSummaryView(ride:saveFailed:onDone:)` where `onDone: (() -> Void)? = nil`. When `onDone` is non-nil, **Done** calls it; otherwise it calls the existing `@Environment(\.dismiss)`.
- Consumed by: Task 5 (`RootView` passes `onDone: { router.popToRoot() }`); `HistoryView` (unchanged — omits `onDone`, keeps `dismiss()`).

- [ ] **Step 1: Add the optional closure property**

In `RideSummaryView` (after `var saveFailed: Bool = false`, `RideSummaryView.swift:9`), add:

```swift
    /// Injected by the ride-end pushed route to return Home via `popToRoot()`. `nil` for the
    /// History sheet, which dismisses itself via `@Environment(\.dismiss)`.
    var onDone: (() -> Void)?
```

- [ ] **Step 2: Wire the Done button to it**

Replace the Done button (`RideSummaryView.swift:82-84`):

```swift
                Button("Done") { dismiss() }
                    .buttonStyle(.ctaPrimary)
                    .padding(.top, AuraTheme.Spacing.xs)
```

with:

```swift
                Button("Done") {
                    if let onDone { onDone() } else { dismiss() }
                }
                    .buttonStyle(.ctaPrimary)
                    .padding(.top, AuraTheme.Spacing.xs)
```

- [ ] **Step 3: Verify (deferred to Task 8 build).** No unit test (app target). `HistoryView.swift:49` (`RideSummaryView(ride: ride)`) still compiles because both `saveFailed` and `onDone` default.

- [ ] **Step 4: Commit**

```bash
git add Aura/Sources/Ride/RideSummaryView.swift
git commit -m "feat(roh-85): RideSummaryView optional onDone (defaults to dismiss)"
```

---

### Task 4: `AppRouter.showRideSummary` (app target)

**Files:**
- Modify: `Aura/Sources/App/AppRouter.swift`

**Interfaces:**
- Consumes: `RideSummaryRouting.collapsed(ride:saveFailed:)` (Task 2), `Ride`.
- Produces: `func showRideSummary(_ ride: Ride, saveFailed: Bool)`.
- Consumed by: Tasks 6 & 7 (the HUDs).

- [ ] **Step 1: Add the method**

In `AppRouter` (after `popToRoot()`, `AppRouter.swift:19`), add:

```swift
    /// Present the finished-ride summary as a pushed route by COLLAPSING the whole path to a
    /// single entry, so only Home sits beneath it (ROH-85). The collapse (and its single-entry
    /// invariant) lives in the pure, unit-tested `RideSummaryRouting.collapsed`. One path write.
    func showRideSummary(_ ride: Ride, saveFailed: Bool) {
        path = RideSummaryRouting.collapsed(ride: ride, saveFailed: saveFailed)
    }
```

- [ ] **Step 2: Verify (deferred to Task 8 build).** `AppRouter` is app-target (no unit test); the collapse logic it calls is tested in Task 2.

- [ ] **Step 3: Commit**

```bash
git add Aura/Sources/App/AppRouter.swift
git commit -m "feat(roh-85): AppRouter.showRideSummary via RideSummaryRouting.collapsed"
```

---

### Task 5: `RootView` `.rideSummary` destination + chrome (app target)

**Files:**
- Modify: `Aura/Sources/AuraApp.swift` (the `RootView` `navigationDestination` switch)

**Interfaces:**
- Consumes: `AppRoute.rideSummary` (Task 1), `RideSummaryView(…, onDone:)` (Task 3), `router.popToRoot()`.
- Produces: makes the enum switch exhaustive again (it will not compile until this case is added).

- [ ] **Step 1: Add the case**

In `RootView.body`'s `switch route` (`AuraApp.swift:90-108`), add a case alongside the others:

```swift
                    case let .rideSummary(payload):
                        // Pushed (not a sheet) so returning Home via popToRoot animates
                        // summary → Home with no HUD to flash (ROH-85). Chrome hidden + swipe
                        // back off so the summary is a terminal screen exited only via Done
                        // (with the path collapsed to one entry, a VoiceOver .escape also lands
                        // on Home). A foreground deep link while this is up replaces the path
                        // (isRideActive is false) — accepted, same as the old sheet.
                        RideSummaryView(ride: payload.ride, saveFailed: payload.saveFailed,
                                        onDone: { router.popToRoot() })
                            .toolbar(.hidden, for: .navigationBar)
                            .navigationBarBackButtonHidden(true)
                            .swipeBackEnabled(false)
```

(These are the same three chrome modifiers `NavigateHUDView` already applies to itself; `joinRide` uses only `navigationBarBackButtonHidden`, so this is a superset — all three are required here.)

- [ ] **Step 2: Verify (deferred to Task 8 build).** The exhaustiveness of the switch is compile-enforced; the Task 8 build confirms.

- [ ] **Step 3: Commit**

```bash
git add Aura/Sources/AuraApp.swift
git commit -m "feat(roh-85): render pushed ride-summary route in RootView"
```

---

### Task 6: `NavigateHUDView` — drop the summary sheet, fold nav into `finishedRide` (app target)

**Files:**
- Modify: `Aura/Sources/Ride/NavigateHUDView.swift`

**Interfaces:**
- Consumes: `router.showRideSummary(_:saveFailed:)` (Task 4), `coordinator.finishedRide`, `coordinator.saveFailed`.

- [ ] **Step 1: Remove the summary sheet**

Delete this modifier block (`NavigateHUDView.swift:168-173`):

```swift
        // Summary sheet: when dismissed, return to the home dashboard.
        .sheet(item: $coordinator.finishedRide, onDismiss: {
            router.popToRoot()
        }, content: { ride in
            RideSummaryView(ride: ride, saveFailed: coordinator.saveFailed)
        })
```

- [ ] **Step 2: Remove the now-unused `@Bindable`**

`$coordinator` (the projected binding) was used ONLY by that sheet (verified: the only `$coordinator` in this file is at `:169`). After deleting the sheet, delete the first line of `body` (`NavigateHUDView.swift:80`):

```swift
        @Bindable var coordinator = coordinator
```

The rest of the body reads `coordinator` (the `@State`) directly — e.g. `coordinator.maneuver`, `coordinator.currentSpeedMetersPerSecond` — which resolves to the `@Observable` `@State` property with no binding needed, so it still compiles. (Leaving the line is not a compile error, but the `@Bindable` becomes pointless; remove it.)

- [ ] **Step 3: Fold navigation into the existing `finishedRide` observer**

Replace the existing observer (`NavigateHUDView.swift:205-207`):

```swift
        .onChange(of: coordinator.finishedRide) { _, ride in
            if ride != nil { WidgetRefresh.reload(rideStore: rideStore, settings: settings) }
        }
```

with:

```swift
        .onChange(of: coordinator.finishedRide) { _, ride in
            guard let ride else { return }
            // Refresh widgets BEFORE navigating: showRideSummary collapses the path and tears
            // this HUD down. saveFailed is already set by finish() (before finishedRide), so it
            // reads correctly here. (ROH-85)
            WidgetRefresh.reload(rideStore: rideStore, settings: settings)
            router.showRideSummary(ride, saveFailed: coordinator.saveFailed)
        }
```

- [ ] **Step 4: Verify (deferred to Task 8 build).**

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/Ride/NavigateHUDView.swift
git commit -m "feat(roh-85): NavigateHUDView pushes summary route instead of sheet"
```

---

### Task 7: `RideHUDView` — same change for free rides (app target)

**Files:**
- Modify: `Aura/Sources/Ride/RideHUDView.swift`

**Interfaces:**
- Consumes: `router.showRideSummary(_:saveFailed:)` (Task 4), `coordinator.finishedRide`, `coordinator.saveFailed`.

- [ ] **Step 1: Remove the summary sheet**

Delete this block (`RideHUDView.swift:130-133`):

```swift
        // Returning from the summary drops to the home dashboard, mirroring NavigateHUDView.
        .sheet(item: $coordinator.finishedRide, onDismiss: { router.popToRoot() }, content: { ride in
            RideSummaryView(ride: ride, saveFailed: coordinator.saveFailed)
        })
```

- [ ] **Step 2: Remove the now-unused `@Bindable`**

`$coordinator` was used ONLY by that sheet (verified: the only `$coordinator` in this file is at `:131`; the gem sheet uses a `gems?.selectedGem` binding, not `$coordinator`). Delete the first line of `body` (`RideHUDView.swift:64`):

```swift
        @Bindable var coordinator = coordinator
```

- [ ] **Step 3: Fold navigation into the existing `finishedRide` observer**

Replace the existing observer (`RideHUDView.swift:180-182`):

```swift
        .onChange(of: coordinator.finishedRide) { _, ride in
            if ride != nil { WidgetRefresh.reload(rideStore: rideStore, settings: settings) }
        }
```

with:

```swift
        .onChange(of: coordinator.finishedRide) { _, ride in
            guard let ride else { return }
            WidgetRefresh.reload(rideStore: rideStore, settings: settings)
            router.showRideSummary(ride, saveFailed: coordinator.saveFailed)
        }
```

- [ ] **Step 4: Verify (deferred to Task 8 build).**

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/Ride/RideHUDView.swift
git commit -m "feat(roh-85): RideHUDView pushes summary route instead of sheet"
```

---

### Task 8: Integration build + lint

**Files:** none (verification only).

- [ ] **Step 1: AuraCore tests green**

Dispatch the `apple-platform-build-tools:builder` agent (or run locally): `swift test --package-path AuraCore`.
Expected: PASS (all suites, including new `AppRouteTests` + `RideSummaryRoutingTests`).

- [ ] **Step 2: App compiles (no simulator boot — other sessions are using sims)**

Dispatch the `apple-platform-build-tools:builder` agent. The Xcode project is generated by **xcodegen and is gitignored** — regenerate it first if the `.xcodeproj` is absent (`xcodegen generate`). Then compile-only against a **generic** simulator destination so no sim is booted or taken from another session:

```
xcodebuild build -scheme Aura -destination 'generic/platform=iOS Simulator' -quiet
```

Expected: BUILD SUCCEEDED. Do **not** run `simctl boot`/`erase`. Watch for any "will never be executed" / unused-binding warnings from the HUD edits (there should be none).

- [ ] **Step 3: SwiftLint strict**

Run: `swiftlint --strict` at repo root.
Expected: no violations. (The HUD edits net-remove lines, so no length rule should newly trip.)

- [ ] **Step 4: Commit any lint fixups** (only if needed)

```bash
git add -A
git commit -m "chore(roh-85): lint fixups"
```

---

## Device verification (pipeline gate, after whole-branch review — not a code task here)

On iPhone 13 Pro Max / iOS 26.5, for **each** of solo-navigate (via search→preview→start, the `[.preview, .navigate]` path), free ride, and group ride, watch both directions:

1. **Entrance:** end the ride; the summary appears cleanly and the HUD transitions *away* naturally (crossfade or push both acceptable — the point is no dead-screen reveal). The entrance style is *not guaranteed* to be a literal right-slide (a path replace may crossfade); if it reads poorly, add a content transition on `RideSummaryView` (do not change the path model).
2. **Exit (the bug):** tap Done → straight to Home, **no HUD/preview flash**; the **Home dashboard sheet reappears without an extra tap** (this is the `HomeView.syncSheet()` re-present on `path.isEmpty` — the attempt-#3 "sheet dropped until next interaction" symptom to hunt for). Watch the navigate case especially: it starts from `[.preview, .navigate]`, so confirm the stale `RoutePreviewView` map never appears.
3. **Summary internals:** the staggered section reveal + hero count-up still play as a pushed destination (they are `.onAppear`-driven; if they no-op because the state flip coalesces into the nav commit, move the reveal trigger in `RideSummaryView` from `.onAppear` to `.task`, scoped so History is unaffected, and re-verify). The share-card render must not visibly jank the entrance.
4. **`saveFailed` banner** still renders (force the save-failure path if feasible, else visual-inspect the happy path).
5. **Group specifics:** crew chrome fully dissolves and does not render during the summary entrance; **both host-end and member-end** reach the summary cleanly; a host-ended guest who keeps riding solo is NOT dropped into a summary.
6. **VoiceOver `.escape`:** with VoiceOver on, the two-finger-scrub escape on the summary lands on Home (not a stale screen) — safe by construction with the single-entry path, but confirm.
7. **History untouched:** its summary sheet still opens and dismisses (swipe-down and Done both reveal History), no flash.

## Self-review notes (coverage)

- Spec "collapse path" → Tasks 2 (pure helper + tests) & 4. New case/payload/hash (+ `saveFailed`-outside-identity comment in BOTH `==` and `hash`) → Task 1. Chrome + deep-link edge comment → Task 5. onDone (+ History unchanged) → Task 3. Fold observer, WidgetRefresh-before-nav, live `saveFailed` → Tasks 6/7. Group guardrails → Global Constraints + device-verify §5. Entrance caveat / reveal fallback / VoiceOver escape / dashboard re-present → device-verify §1/§2/§3/§6. Build/lint → Task 8.
- Type consistency: `RideSummaryPayload(ride:saveFailed:)`, `AppRoute.rideSummary(_)`, `RideSummaryRouting.collapsed(ride:saveFailed:)`, `showRideSummary(_:saveFailed:)`, `RideSummaryView(ride:saveFailed:onDone:)` used identically across tasks.
- No app-target unit tests invented; pure logic (AppRoute identity + path collapse) is TDD'd in AuraCore, SwiftUI wiring is build + device verified.
- Build coupling (app target non-compiling Tasks 1→5) is called out in Global Constraints so a per-task reviewer doesn't mistake it for a defect.
