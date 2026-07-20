# Ride-Summary Dismiss-Flash Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the ride HUD from flashing for ~0.5s when the ride-summary is dismissed, by making the summary a pushed `NavigationStack` route reached by collapsing the path to a single entry, instead of a `.sheet` hosted on the HUD.

**Architecture:** On ride finish, the HUD observes `coordinator.finishedRide` and calls `router.showRideSummary(ride, saveFailed:)`, which sets `path = [.rideSummary(payload)]` — collapsing the whole nav path so only Home sits beneath the summary. `RootView` renders `RideSummaryView` for that route (nav chrome hidden, swipe-back off). **Done** calls `router.popToRoot()`, a single-level pop straight to Home with nothing to flash. `HistoryView` keeps presenting `RideSummaryView` as its own sheet, unchanged.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`import Testing`), SwiftPM package `AuraCore` (contains `AppRoute` + its tests) and the Xcode app target `Aura` (contains `AppRouter`, `RootView`, the HUDs, `RideSummaryView` — no test bundle, verified by build + device).

## Global Constraints

- Swift 6 strict concurrency; all touched types are `@MainActor` or `Sendable` as they already are.
- `AppRoute` is `public enum AppRoute: Sendable` with **hand-written** `Equatable`/`Hashable` that hash each case by payload **id**, never by content. The new case must follow this exactly (hash by `ride.id`).
- App target (`Aura/Sources/**`) has **no unit-test bundle** (established convention). Pure logic that needs a test goes in `AuraCore`; app-target SwiftUI wiring is verified by compiling the app scheme and by device verification.
- `swiftlint --strict` must pass locally before merge (local merges skip CI SwiftLint).
- Do **not** change `RideSessionCoordinator`, `NavigateHUDView+GroupCrew`, or the History sheet.
- Do **not** add any `onChange(of: groupSession?.phase)` auto-finish (would tear down a still-riding guest — ROH-81 class bug).
- Delegate all Xcode/simulator builds to the `apple-platform-build-tools:builder` agent; it absorbs verbose logs and returns pass/fail.

---

### Task 1: `AppRoute.rideSummary` case + `RideSummaryPayload` (AuraCore, TDD)

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Navigation/AppRoute.swift`
- Test: `AuraCore/Tests/AuraCoreTests/AppRouteTests.swift`

**Interfaces:**
- Consumes: `Ride` (`AuraCore/Sources/AuraCore/Models/Ride.swift`, a `public struct … Sendable` with `id: UUID`).
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

`TrackPoint`'s initializer is `TrackPoint(coordinate:elevation:timestamp:speedMetersPerSecond:)` with `speedMetersPerSecond` defaulted (verified against `AuraCore/Sources/AuraCore/Models/TrackPoint.swift`) — the point's contents are irrelevant to route identity.

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

Ask the builder agent to run the AuraCore test suite (or run locally):
`swift test --package-path AuraCore --filter AppRouteTests`
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

And to `func hash(into:)` (add a new case; `6` is taken by `.settings`, so use `7`):

```swift
        case let .rideSummary(payload):
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

### Task 2: `RideSummaryView.onDone` hook (app target)

**Files:**
- Modify: `Aura/Sources/Ride/RideSummaryView.swift`

**Interfaces:**
- Produces: `RideSummaryView(ride:saveFailed:onDone:)` where `onDone: (() -> Void)? = nil`. When `onDone` is non-nil, **Done** calls it; otherwise it calls the existing `@Environment(\.dismiss)`.
- Consumed by: Task 4 (`RootView` passes `onDone: { router.popToRoot() }`); `HistoryView` (unchanged — omits `onDone`, keeps `dismiss()`).

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

- [ ] **Step 3: Verify (deferred to Task 7 build)**

No unit test (app target). This compiles as part of the Task 7 app build. `HistoryView.swift:49` (`RideSummaryView(ride: ride)`) still compiles because `onDone` defaults to `nil`.

- [ ] **Step 4: Commit**

```bash
git add Aura/Sources/Ride/RideSummaryView.swift
git commit -m "feat(roh-85): RideSummaryView optional onDone (defaults to dismiss)"
```

---

### Task 3: `AppRouter.showRideSummary` (app target)

**Files:**
- Modify: `Aura/Sources/App/AppRouter.swift`

**Interfaces:**
- Consumes: `AppRoute.rideSummary` + `RideSummaryPayload` (Task 1), `Ride`.
- Produces: `func showRideSummary(_ ride: Ride, saveFailed: Bool)` — sets `path = [.rideSummary(...)]`.
- Consumed by: Tasks 5 & 6 (the HUDs).

- [ ] **Step 1: Add the method**

In `AppRouter` (after `popToRoot()`, `AppRouter.swift:19`), add:

```swift
    /// Present the finished-ride summary as a pushed route by COLLAPSING the whole path to this
    /// single entry, so only Home sits beneath it (ROH-85). One path write (assignment) — it
    /// cannot race itself, and leaves nothing (HUD, preview, lobby) beneath to flash when Done
    /// later calls `popToRoot()`. Every ride end already returns to Home, so discarding the
    /// prior path entries matches existing behavior.
    func showRideSummary(_ ride: Ride, saveFailed: Bool) {
        path = [.rideSummary(RideSummaryPayload(ride: ride, saveFailed: saveFailed))]
    }
```

- [ ] **Step 2: Verify (deferred to Task 7 build).** No unit test — `AppRouter` is app-target. Logic is a single assignment; verified by build + device.

- [ ] **Step 3: Commit**

```bash
git add Aura/Sources/App/AppRouter.swift
git commit -m "feat(roh-85): AppRouter.showRideSummary collapses path to summary route"
```

---

### Task 4: `RootView` `.rideSummary` destination + chrome (app target)

**Files:**
- Modify: `Aura/Sources/AuraApp.swift` (the `RootView` `navigationDestination` switch)

**Interfaces:**
- Consumes: `AppRoute.rideSummary` (Task 1), `RideSummaryView(…, onDone:)` (Task 2), `router.popToRoot()`.
- Produces: nothing new; makes the enum switch exhaustive again (it will not compile until this case is added).

- [ ] **Step 1: Add the case**

In `RootView.body`'s `switch route` (`AuraApp.swift:90-108`), add a case alongside the others (mirror the `joinRide` chrome pattern):

```swift
                    case let .rideSummary(payload):
                        // Pushed (not a sheet) so returning Home via popToRoot animates
                        // summary → Home with no HUD to flash (ROH-85). Chrome hidden + swipe
                        // back off so the summary is a terminal screen exited only via Done.
                        RideSummaryView(ride: payload.ride, saveFailed: payload.saveFailed,
                                        onDone: { router.popToRoot() })
                            .toolbar(.hidden, for: .navigationBar)
                            .navigationBarBackButtonHidden(true)
                            .swipeBackEnabled(false)
```

- [ ] **Step 2: Verify (deferred to Task 7 build).** The exhaustiveness of the switch is compile-enforced; the Task 7 build confirms.

- [ ] **Step 3: Commit**

```bash
git add Aura/Sources/AuraApp.swift
git commit -m "feat(roh-85): render pushed ride-summary route in RootView"
```

---

### Task 5: `NavigateHUDView` — drop the summary sheet, fold nav into `finishedRide` (app target)

**Files:**
- Modify: `Aura/Sources/Ride/NavigateHUDView.swift`

**Interfaces:**
- Consumes: `router.showRideSummary(_:saveFailed:)` (Task 3), `coordinator.finishedRide`, `coordinator.saveFailed`.

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

`$coordinator` was used ONLY by that sheet. Delete the first line of `body` (`NavigateHUDView.swift:80`):

```swift
        @Bindable var coordinator = coordinator
```

(The rest of the body reads `coordinator` — the `@State` — directly; no other `$coordinator` binding exists. Leaving the line causes an unused-warning / SwiftLint failure.)

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

- [ ] **Step 4: Verify (deferred to Task 7 build).**

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/Ride/NavigateHUDView.swift
git commit -m "feat(roh-85): NavigateHUDView pushes summary route instead of sheet"
```

---

### Task 6: `RideHUDView` — same change for free rides (app target)

**Files:**
- Modify: `Aura/Sources/Ride/RideHUDView.swift`

**Interfaces:**
- Consumes: `router.showRideSummary(_:saveFailed:)` (Task 3), `coordinator.finishedRide`, `coordinator.saveFailed`.

- [ ] **Step 1: Remove the summary sheet**

Delete this block (`RideHUDView.swift:130-133`):

```swift
        // Returning from the summary drops to the home dashboard, mirroring NavigateHUDView.
        .sheet(item: $coordinator.finishedRide, onDismiss: { router.popToRoot() }, content: { ride in
            RideSummaryView(ride: ride, saveFailed: coordinator.saveFailed)
        })
```

- [ ] **Step 2: Remove the now-unused `@Bindable`**

`$coordinator` was used ONLY by that sheet (the gem sheet uses a `gems?.selectedGem` binding, not `$coordinator`). Delete the first line of `body` (`RideHUDView.swift:64`):

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

- [ ] **Step 4: Verify (deferred to Task 7 build).**

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/Ride/RideHUDView.swift
git commit -m "feat(roh-85): RideHUDView pushes summary route instead of sheet"
```

---

### Task 7: Integration build + lint

**Files:** none (verification only).

- [ ] **Step 1: AuraCore tests green**

Dispatch the builder agent: run `swift test --package-path AuraCore`.
Expected: PASS (all suites, including new AppRouteTests).

- [ ] **Step 2: App builds for the simulator**

Dispatch the builder agent: build the `Aura` app scheme for the iOS Simulator (iPhone 17 sim, per repo convention). Discover scheme/sim automatically.
Expected: BUILD SUCCEEDED, no warnings about unused `@Bindable`/`$coordinator`.

- [ ] **Step 3: SwiftLint strict**

Run: `swiftlint --strict` at repo root.
Expected: no violations. (If a HUD body now trips a length rule after the edits, it should not — the edits net-remove lines.)

- [ ] **Step 4: Commit any lint fixups** (only if needed)

```bash
git add -A
git commit -m "chore(roh-85): lint fixups"
```

---

## Device verification (pipeline task, after whole-branch review — not a code task here)

On iPhone 13 Pro Max / iOS 26.5, for **each** of solo-navigate (via search→preview→start), free ride, and group ride, watch both directions:

1. **Entrance:** summary appears cleanly; the HUD transitions *away* naturally (crossfade/push both acceptable — the point is no dead-screen reveal).
2. **Exit (the bug):** Done → straight to Home, **no HUD/preview flash**; the Home dashboard sheet reappears **without an extra tap**.
3. **Summary internals:** staggered reveal + hero count-up still play; share-card render doesn't jank the entrance. *If reveal/count-up no-op*, move the reveal trigger in `RideSummaryView` from `.onAppear` to `.task` (scoped so History is unaffected) and re-verify.
4. **`saveFailed` banner** renders (force the save-failure path if feasible).
5. **Group:** crew chrome fully dissolves and does not render during the summary entrance; both **host-end** and **member-end** reach the summary cleanly.
6. **History untouched:** its summary sheet still opens and dismisses (swipe-down and Done both reveal History), no flash.

## Self-review notes (coverage)

- Spec "collapse path" → Task 3. New case/payload/hash → Task 1 (+ comment on `saveFailed` outside identity). Chrome → Task 4. onDone (+ History unchanged) → Task 2. Fold observer, WidgetRefresh-before-nav, live `saveFailed` → Tasks 5/6. Group guardrails → Global Constraints + device-verify §5. Entrance caveat + reveal fallback → device-verify §1/§3. Build/lint → Task 7.
- Type consistency: `RideSummaryPayload(ride:saveFailed:)`, `AppRoute.rideSummary(_)`, `showRideSummary(_:saveFailed:)`, `RideSummaryView(ride:saveFailed:onDone:)` used identically across tasks.
- No app-target unit tests invented; pure logic (AppRoute) is TDD'd, SwiftUI wiring is build + device verified.
