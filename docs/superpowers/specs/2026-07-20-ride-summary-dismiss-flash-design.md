# ROH-85 — Ride-summary dismiss flash: presentation-model redesign

**Date:** 2026-07-20
**Issue:** ROH-85 (team Rohun, project "Summary & Map Polish", Low priority)
**Background:** `docs/known-issues/ride-summary-dismiss-flash.md`

## Problem

At the end of any ride, tapping **Done** on the summary slides the sheet down and — for
~0.5s — reveals the just-ended ride HUD before the app pops back to Home. It reads as a
stale-screen flash.

Root cause: the summary is a `.sheet(item: $coordinator.finishedRide, onDismiss: { router.popToRoot() })`
hosted **by the HUD**. Dismissing a sheet uncovers its presenter (the HUD); `popToRoot()`
only runs *after* the dismiss animation finishes. So the user sees: summary slides down →
HUD revealed → nav pops to Home. The middle step is the flash. Because the sheet is hosted
by the HUD, you cannot remove the HUD before the sheet dismisses.

Affects **all three ride types** (solo navigate `NavigateHUDView`, free ride `RideHUDView`,
group ride — which reuses `NavigateHUDView` via `GroupNavigateContainer`). This is a shared,
load-bearing flow: a regression breaks every ride's ending.

Four prior attempts failed (instant `popToRoot`, mask overlay, lifting the sheet to root,
various orderings). See the known-issue doc for why each failed; do not repeat them. The
throughline: **a `.sheet` and a `NavigationStack` path change fight each other in every
ordering.**

## Approach: summary as a pushed `NavigationStack` route

Stop hosting the summary as a sheet on the HUD. Make the finished ride a **navigation
destination** on the app's single `NavigationStack(path: $router.path)`, reached by
**replacing the HUD's top path entry**. Returning Home is `popToRoot()`, which animates the
summary → Home directly with no HUD in the stack to flash.

This is pure `NavigationStack` path mutation — there is no `.sheet`/`.fullScreenCover`
interacting with a path change anywhere in the ride-end flow, which is the exact class of bug
that sank the prior root-sheet attempt.

**Entrance animation (PO decision, 2026-07-20):** standard horizontal push. The summary
slides in from the right like a screen; Done slides it back to Home. It loses swipe-down-to-
dismiss; the rider taps Done. Accepted.

### Data flow

1. `RideSessionCoordinator.finish()` is unchanged. It still sets `saveFailed` (line 150/152)
   then publishes `finishedRide` (line 154). Ordering matters and is already correct: any
   observer of `finishedRide` reads the freshly-set `saveFailed`.

2. Each HUD replaces its existing `.sheet(item: $coordinator.finishedRide, …)` with an
   observer:

   ```swift
   .onChange(of: coordinator.finishedRide) { _, ride in
       guard let ride else { return }
       WidgetRefresh.reload(rideStore: rideStore, settings: settings)   // fold in existing refresh
       router.showRideSummary(ride, saveFailed: coordinator.saveFailed)
   }
   ```

   (Both HUDs already have an `onChange(of: coordinator.finishedRide)` doing the widget
   refresh; the navigation is folded into that same handler so there is exactly one.)

3. `AppRouter.showRideSummary(_:saveFailed:)` **replaces the top path entry** (does not push
   on top of it), so the HUD leaves the stack:

   ```swift
   func showRideSummary(_ ride: Ride, saveFailed: Bool) {
       let route = AppRoute.rideSummary(.init(ride: ride, saveFailed: saveFailed))
       if path.isEmpty { path = [route] } else { path[path.count - 1] = route }
   }
   ```

   One path write. This mirrors the existing `replaceTopWithGroupRide` pattern, which exists
   precisely to avoid the `dismiss()` + `push()` two-writes-in-one-tick race.

4. `RootView`'s `navigationDestination` renders the summary for the new case, with the same
   chrome the HUDs use:

   ```swift
   case let .rideSummary(payload):
       RideSummaryView(ride: payload.ride, saveFailed: payload.saveFailed,
                       onDone: { router.popToRoot() })
           .toolbar(.hidden, for: .navigationBar)
           .navigationBarBackButtonHidden(true)
           .swipeBackEnabled(false)
   ```

5. `RideSummaryView`'s **Done** calls the injected `onDone` if present, else `dismiss()`:

   ```swift
   var onDone: (() -> Void)?
   ...
   Button("Done") {
       if let onDone { onDone() } else { dismiss() }
   }
   ```

   The ride-end route passes `{ router.popToRoot() }`. `HistoryView` (sheet-over-History) omits
   `onDone`, so its Done still calls `dismiss()` and reveals History — unchanged, no flash.

### New types

- `AppRoute.rideSummary(RideSummaryPayload)` — added to `AuraCore/.../AppRoute.swift`.
- `RideSummaryPayload` — a `Sendable` struct `{ ride: Ride, saveFailed: Bool }`. `AppRoute`'s
  hand-written `Equatable`/`Hashable` hash this case by `ride.id` only (matching how every
  other `AppRoute` case hashes by payload id, never by content), so the path stays cheap to
  hash and never hashes a track.

## Why each ride type is covered

- **Solo navigate:** path is `[.navigate(...)]` (or `[.preview, .navigate]` from the
  preview→start flow). Replace top → `[.rideSummary]` (or `[.preview, .rideSummary]`). Done =
  `popToRoot()` clears everything to Home in one animated transaction. The HUD is gone before
  any animation, so nothing flashes; the `.preview` beneath (if present) is removed in the same
  `popToRoot` transaction and does not flash either.
- **Free ride:** path `[.freeRide]` → `[.rideSummary]`. Same as above.
- **Group ride:** path `[.groupRide(entry)]`. The group HUD *is* `NavigateHUDView` (with a
  `groupSession`), so the same `onChange` fires. Replace top → `[.rideSummary]`; the whole
  `GroupRideFlowView` (and its session) is torn down by the outer path change, which is the
  desired cleanup. `GroupRideFlowView` deliberately hosts no nested `NavigationStack`
  (documented in its `.needsDisplayName` comment), so there is nothing to swallow the outer
  path change.

## Teardown safety

Replacing the top entry tears down the HUD → its `.onDisappear` runs
`coordinator.cancel()` + `router.isRideActive = false`. Verified safe:

- `cancel()` (coordinator line 165) only detaches guidance, stops streaming, releases the
  screen, and ends the Live Activity. It does **not** touch `finishedRide` or the saved ride,
  and `activity.end()` is idempotent after `finish()`.
- The `.rideSummary` payload holds the `Ride` by value and `saveFailed` as a captured `Bool`,
  so the summary renders fully even though the coordinator that produced it is gone. This is
  strictly more robust than the sheet, which read `coordinator.saveFailed` live.
- `router.isRideActive` correctly becomes `false` on the summary screen (the ride is over),
  so a deep link on the summary behaves like a deep link on Home.

## Testing

Pure, app-target-free logic is unit-tested in `AuraCore` (the app target has no test bundle,
per existing convention — see `AppRoute.stack(for:)` tests):

1. **`AppRoute` equality/hash for `.rideSummary`** — two payloads with the same `ride.id`
   compare equal and hash equal regardless of `saveFailed` or track content; different
   `ride.id` compare unequal. (Mirrors the existing `.navigate`/`.preview` hash tests.)
2. **`AppRouter.showRideSummary`** replace-top semantics:
   - empty path → `[.rideSummary]`
   - `[.navigate]` → `[.rideSummary]` (length 1, HUD replaced not stacked)
   - `[.preview, .navigate]` → `[.preview, .rideSummary]` (length unchanged, top replaced)
   - carries the passed `ride`/`saveFailed` into the payload.
3. **`popToRoot()` from a summary path** empties the path (already covered by existing
   `popToRoot` behavior; add an assertion from a `[.preview, .rideSummary]` start).

Device verification (the flash is a device-only animation artifact — sim is not authoritative):
on iPhone 13 Pro Max / iOS 26.5, end a ride of each of the three types and watch **both** the
entrance (push in) and the Done dismiss (pop straight to Home, **no HUD flash**). Confirm the
`saveFailed` banner still renders (force a save failure path if feasible, else visual-inspect
the happy path) and that History's summary sheet still opens and dismisses correctly.

## Files

- `AuraCore/Sources/AuraCore/Navigation/AppRoute.swift` — new `.rideSummary` case +
  `RideSummaryPayload`; extend hand-written `Equatable`/`Hashable`.
- `Aura/Sources/App/AppRouter.swift` — `showRideSummary(_:saveFailed:)`.
- `Aura/Sources/AuraApp.swift` (`RootView`) — new `navigationDestination` case with chrome.
- `Aura/Sources/Ride/NavigateHUDView.swift` — drop the summary `.sheet`; fold navigation into
  the `finishedRide` `onChange`.
- `Aura/Sources/Ride/RideHUDView.swift` — same change.
- `Aura/Sources/Ride/RideSummaryView.swift` — optional `onDone` closure; Done uses it.
- `Aura/Sources/History/HistoryView.swift` — unchanged (omits `onDone`).
- `AuraCore/Tests/…` — `AppRoute` + `AppRouter` unit tests above.

## Non-goals

- No change to `RideSummaryView`'s content, layout, hero, share card, or the History sheet.
- No custom/bespoke navigation transition (standard push, per the PO decision).
- No change to `RideSessionCoordinator`.
- The pre-existing entrance behavior of History's summary sheet is unchanged.

## Risks

- **Regression on a load-bearing flow.** Mitigated by: one shared code path, unit tests on the
  pure router/route logic, and mandatory device verification of all three ride types before
  merge.
- **Double-observer on `finishedRide`.** Both HUDs already observe it for widget refresh; the
  plan folds navigation into that single handler rather than adding a second `onChange`, to
  avoid ordering ambiguity between two observers of the same value.
