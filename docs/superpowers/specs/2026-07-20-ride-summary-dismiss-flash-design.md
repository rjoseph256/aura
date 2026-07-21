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
**collapsing the whole path to a single `.rideSummary` entry** so that **only Home sits
beneath it**. Returning Home is `popToRoot()` (a guaranteed single-level pop from the
collapsed path), which animates the summary → Home directly with no HUD *and no other
screen* in the stack to flash.

This is pure `NavigationStack` path mutation — there is no `.sheet`/`.fullScreenCover`
interacting with a path change anywhere in the ride-end flow, which is the exact class of bug
that sank the prior root-sheet attempt.

**Why collapse the path, not just swap the top entry (spec-review reconciliation).** The
navigate-from-search flow leaves the path as `[.preview, .navigate]` (`RoutePreviewView`
pushes `.navigate` *on top of* `.preview`, `RoutePreviewView.swift:273`). Merely replacing the
top (`path[last] = .rideSummary`) would leave `[.preview, .rideSummary]` — the stale full-bleed
`RoutePreviewView` map directly beneath the summary. Done's `popToRoot()` would then pop **two**
entries over that stale map, re-creating the exact "stale full-screen behind the summary for
~0.5s" bug this ticket exists to kill — just with the preview map instead of the HUD. Two
independent adversarial reviewers converged on this as the highest-severity flaw. Collapsing to
`path = [.rideSummary]` eliminates it: there is nothing but Home beneath, so **every** exit
(Done, an accidental pop, or the VoiceOver `.escape` gesture — none of which we can fully
suppress) lands on Home, never on a stale intermediate. It is still a single path write, and it
matches today's invariant that every ride end returns to Home via `popToRoot()`.

**Entrance animation (PO decision 2026-07-20, with a reconciliation caveat).** The PO approved a
"standard push" entrance (summary slides in like a screen; Done returns to Home; loses
swipe-down-to-dismiss — the rider taps Done; accepted). Caveat surfaced in review: a
NavigationStack path *replace* (as opposed to an append/push) does not *guarantee* a literal
slide-in-from-the-right; SwiftUI may render it as a crossfade or pop-style transition. This is
**cosmetic only** — at ride end, transitioning *away from* the HUD you were just looking at is
natural regardless of style; the bug is strictly about a dead HUD reappearing on *exit*, which
the collapse fixes. The exact entrance style is a device-verification item (below); exit safety
takes priority over entrance nicety. If the entrance reads poorly on device, the fallback is a
light content transition on `RideSummaryView`, not a change to the path model.

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

3. `AppRouter.showRideSummary(_:saveFailed:)` **collapses the whole path** to the single
   summary entry, so nothing — HUD, preview, or lobby — remains beneath it:

   ```swift
   func showRideSummary(_ ride: Ride, saveFailed: Bool) {
       path = [.rideSummary(.init(ride: ride, saveFailed: saveFailed))]
   }
   ```

   One path write (assignment), so it cannot race itself — the same single-write property that
   made `replaceTopWithGroupRide` safe, with the added guarantee that only Home is beneath.
   `saveFailed` is read live from the coordinator at the call site (below); safe because
   `finish()` sets `saveFailed` *before* it publishes `finishedRide`.

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

   The three chrome modifiers are mandatory: without them the summary shows a system nav bar
   and a live back button, and with swipe-back enabled a real ride could be swiped away. This
   mirrors the treatment `joinRide` already uses. With the path collapsed to a single entry,
   the VoiceOver `.escape` gesture (which `swipeBackEnabled(false)` does *not* disable — it only
   touches the interactive pop gesture) pops the single entry and lands on Home, which is
   correct — no extra handling needed. (If `RideSummaryView` later grows a bespoke escape
   action, route it through `onDone` for consistency.)

5. `RideSummaryView`'s **Done** calls the injected `onDone` if present, else `dismiss()`:

   ```swift
   var onDone: (() -> Void)?
   ...
   Button("Done") {
       if let onDone { onDone() } else { dismiss() }
   }
   ```

   `onDone` **defaults to `nil`**, so `HistoryView`'s existing call `RideSummaryView(ride: ride)`
   (`HistoryView.swift:49`) compiles unchanged and its Done still calls `dismiss()` to reveal
   History — no flash there. **Do not** pass `onDone` at the History call site "for consistency":
   that would make History's Done `popToRoot` and regress its sheet dismissal. The ride-end
   route passes `{ router.popToRoot() }`. (With the path collapsed to `[.rideSummary]`, even the
   `dismiss()` fallback would reach Home if it ever fired on the pushed route — but the route
   always injects `onDone`, so it never does.)

### New types

- `AppRoute.rideSummary(RideSummaryPayload)` — added to `AuraCore/.../AppRoute.swift`.
- `RideSummaryPayload` — a `Sendable` struct `{ ride: Ride, saveFailed: Bool }`. `Ride` is a
  `Sendable` value type (`AuraCore/Models/Ride.swift`), so the payload is `Sendable` (keeping
  `AppRoute: Sendable`) and held by value; `Ride.id` is a non-optional stable `UUID`. `AppRoute`'s
  hand-written `Equatable`/`Hashable` hash this case by `ride.id` only (matching how every
  other `AppRoute` case hashes by payload id, never by content), so the path stays cheap to
  hash and never hashes a track (the `track` array is COW; equality/hash ignore it).
- **Add a code comment on the hand-written `==`/`hash`** noting `saveFailed` is *deliberately
  outside identity*: the route is built once with `saveFailed` captured by value and never
  mutated in place, so NavigationStack never needs to observe a flip. This prevents a future
  footgun where re-pushing a summary for the same `ride.id` with a different `saveFailed` would
  be treated as identical and not re-render.

## Why each ride type is covered

All three collapse to `path = [.rideSummary]`, so Done is always a single-level pop to Home
with nothing but Home beneath.

- **Solo navigate:** path is `[.preview, .navigate]` (the common search→preview→start flow;
  `RoutePreviewView.swift:273` pushes `.navigate` on top of `.preview`). Collapse →
  `[.rideSummary]`. Done = `popToRoot()` pops the single entry to Home; the preview is already
  gone (collapsed at ride end, not on Done), so it cannot flash on exit.
- **Free ride:** path `[.freeRide]` → `[.rideSummary]`.
- **Group ride:** path `[.groupRide(entry)]` → `[.rideSummary]`. The group HUD *is*
  `NavigateHUDView` (with a `groupSession`), so the same `onChange` fires. Collapsing the path
  tears down the whole `GroupRideFlowView` and its `@State GroupRideSession` — the desired
  cleanup. `GroupRideFlowView` deliberately hosts no nested `NavigationStack` (documented in its
  `.needsDisplayName` comment), so there is nothing to swallow the outer path change.

### Group-ride implementer guardrails (from spec review)

- **The nav trigger fires only from the rider's own `finish()`.** Only `endGroupRideAsHost`,
  `endRideAsMember`, and the `Retry` path call `endRide()`/`finish()` (`NavigateHUDView+GroupCrew.swift`).
  **Do NOT** add an `onChange(of: groupSession?.phase)`-style auto-finish. On a host-end a guest
  goes `.ended` but keeps riding solo (D10); `GroupRideFlowView.content` deliberately keeps the
  HUD alive via `.ended && didEnterRiding`. A phase observer would tear that guest's ride down
  and is exactly the ROH-81 class of bug.
- **Teardown now happens ~0.5s earlier** (at `finish()`, not at Done). This is safe because the
  payload holds the `Ride` by value, and `endGroupRideAsHost()` **awaits** `groupSession.end()`
  to server confirmation *before* calling `finish()`, so the host-left broadcast is not
  truncated. Device-verify the group-host and group-member end paths specifically.
- **Keep `+GroupCrew`'s one-runloop `endRide()` deferral.** It was written so the phase-driven
  crew-chrome dissolve commits in a separate transaction from the summary presentation; it still
  serves that purpose with the path-replace. Device-verify the crew chrome fully dissolves and
  does not briefly render during the summary's entrance.

## Teardown safety

Collapsing the path tears down the HUD → its `.onDisappear` runs
`coordinator.cancel()` + `router.isRideActive = false`. Verified safe:

- `cancel()` (coordinator line 165) only detaches guidance, stops streaming, releases the
  screen, and ends the Live Activity. It does **not** touch `finishedRide` or the saved ride,
  and `activity.end()` is idempotent after `finish()`.
- `finish()` runs on a still-mounted, still-live coordinator; the `onChange` captures `ride`
  (and `saveFailed`) by value into the payload *before* the path mutation triggers teardown. So
  the ROH-81 "summary set on a destroyed coordinator" failure is genuinely avoided.
- The `.rideSummary` payload holds the `Ride` by value and `saveFailed` as a captured `Bool`,
  so the summary renders fully even though the coordinator that produced it is gone. This is
  strictly more robust than the sheet, which read `coordinator.saveFailed` live.
- `router.isRideActive` correctly becomes `false` on the summary screen (the ride is over),
  so a deep link on the summary behaves like a deep link on Home. **Known, accepted edge (not a
  regression):** a foreground deep link (or the `-openURL` UI-test hook) while the summary is up
  runs `handle(url:)` → `path = AppRoute.stack(for:)`, which replaces the `.rideSummary` route
  and, for an unsaved ride, its "couldn't save" notice. The old sheet lost it the same way (a
  root path write tore down the presenter), so behavior is equivalent; noted, not fixed here.

## Environment inheritance

`RideSummaryView` reads `RideStore`, `SettingsStore`, and the accessibility environment from
the SwiftUI environment. These are injected at `RootView`'s root (`AuraApp.swift`), so a
`navigationDestination` child inherits them exactly as the sheet did — nothing about the summary
required the HUD to stay alive behind it. The only live coordinator read today
(`coordinator.saveFailed` in the sheet content) is replaced by the value captured in the payload.

## Testing

Pure, app-target-free logic is unit-tested in `AuraCore` (the app target has no test bundle,
per existing convention — see `AppRoute.stack(for:)` tests):

1. **`AppRoute` equality/hash for `.rideSummary`** — two payloads with the same `ride.id`
   compare equal and hash equal regardless of `saveFailed` or track content; different
   `ride.id` compare unequal. (Mirrors the existing `.navigate`/`.preview` hash tests.)
2. **`AppRouter.showRideSummary`** path-collapse semantics — the result is always exactly
   `[.rideSummary]`, regardless of the starting path:
   - empty path → `[.rideSummary]`
   - `[.freeRide]` → `[.rideSummary]`
   - `[.preview, .navigate]` → `[.rideSummary]` (**length 1** — preview and HUD both gone)
   - `[.groupRide(...)]` → `[.rideSummary]`
   - carries the passed `ride`/`saveFailed` into the payload.
3. **`popToRoot()` from `[.rideSummary]`** empties the path (single-level pop to Home).

Device verification (the flash is a device-only animation artifact — sim is not authoritative;
run on iPhone 13 Pro Max / iOS 26.5). For **each** of solo-navigate (via search→preview→start,
the `[.preview, …]` path), free ride, and group ride, watch **both** directions:

1. **Entrance:** end the ride; the summary appears cleanly (transition style noted — a crossfade
   or push are both acceptable; what matters is no jarring reveal of a *dead* screen). Confirm
   the HUD you were on transitions *away* naturally.
2. **Exit (the bug):** tap Done; confirm the app goes **straight to Home with no HUD/preview
   flash**, and the **Home dashboard sheet reappears without an extra tap** (the
   `syncSheet()`/`path.isEmpty` re-present — the attempt-#3 symptom to watch for).
3. **Summary internals still animate:** the staggered section reveal and the hero count-up still
   play as a pushed destination (they are `.onAppear`-driven; if they no-op because the state
   flip coalesces into the nav commit, drive `revealed` from `.task`/a one-tick delay as a
   scoped fallback). The share-card render must not visibly jank the entrance.
4. **`saveFailed` banner** still renders (force the save-failure path if feasible, else
   visual-inspect the happy path).
5. **Group specifics:** crew chrome fully dissolves and does not render during the summary
   entrance; both host-end and member-end paths reach the summary cleanly.
6. **History untouched:** History's summary still opens and dismisses as a sheet (swipe-down and
   Done both reveal History), no flash.

## Files

- `AuraCore/Sources/AuraCore/Navigation/AppRoute.swift` — new `.rideSummary` case +
  `RideSummaryPayload`; extend hand-written `Equatable`/`Hashable`.
- `Aura/Sources/App/AppRouter.swift` — `showRideSummary(_:saveFailed:)` (collapses the path).
- `Aura/Sources/AuraApp.swift` (`RootView`) — new `navigationDestination` case with chrome.
- `Aura/Sources/Ride/NavigateHUDView.swift` — drop the summary `.sheet`; **fold** navigation
  into the *existing* `onChange(of: coordinator.finishedRide)` (which already does the widget
  refresh — do not add a second observer of the same value). Keep `WidgetRefresh.reload` *before*
  `showRideSummary` (the latter tears the HUD down). Read `coordinator.saveFailed` live there.
- `Aura/Sources/Ride/RideHUDView.swift` — same change (also has the existing `finishedRide`
  observer).
- `Aura/Sources/Ride/RideSummaryView.swift` — optional `onDone` closure (defaults `nil`); Done
  uses it, falling back to `dismiss()`.
- `Aura/Sources/History/HistoryView.swift` — unchanged (omits `onDone` → keeps `dismiss()`).
- `AuraCore/Tests/…` — `AppRoute` + `AppRouter` unit tests above.

## Non-goals

- No change to `RideSummaryView`'s content, layout, hero, or share card (only the added `onDone`
  hook and, *if device verification requires it*, moving the reveal trigger from `.onAppear` to
  `.task`).
- No bespoke/custom `NavigationStack` transition. The entrance is whatever the path-replace
  yields (device-verified); polish, if needed, is a content transition, not a path-model change.
- No change to `RideSessionCoordinator`, `NavigateHUDView+GroupCrew`, or the History sheet.

## Risks

- **Regression on a load-bearing flow.** Mitigated by: one shared code path, unit tests on the
  pure router/route logic, and mandatory device verification of all three ride types (both
  directions) before merge.
- **Entrance animation not a literal push.** A path *replace* may render as a crossfade/pop
  rather than a slide-in. Cosmetic (transitioning away from the just-viewed HUD is natural);
  device-verified; fallback is a content transition. Does not affect the exit fix.
- **Double-observer on `finishedRide`.** Both HUDs already observe it for widget refresh; the
  plan folds navigation into that single handler rather than adding a second `onChange`, to
  avoid ordering ambiguity between two observers of the same value.
- **`.onAppear`-driven reveal/count-up may not animate** as a pushed destination if the state
  flip coalesces into the nav commit. Fallback: drive `revealed` from `.task`/a one-tick delay
  (scoped so History is unaffected). A device-verification gate, not a blind change.
- **Group session torn down ~0.5s earlier.** Safe by construction (host awaits `end()` before
  `finish()`; payload holds the ride by value); the guardrails above forbid the phase-observer
  pattern that would break a still-riding guest. Device-verify both group end paths.
