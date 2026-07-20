# Ride-summary dismiss flash (ride HUD briefly visible before Home)

**Status:** open, pre-existing. Not part of ROH-81 (which fixed the End/Leave feedback, pill
placement, and the HUD-recreation bug). Split out here so it can be fixed with a proper design
pass instead of trial-and-error in a device loop.

## Symptom

At the end of any ride, tapping **Done** on the summary card slides the sheet down and — for
roughly half a second — reveals the just-ended ride HUD (map, turn card, instrument panel)
before the app pops back to Home. It reads as a stale-screen flash. Observed on device
(iPhone 13 Pro Max, iOS 26.5) during ROH-81 group-ride testing, but it is **not group-specific**:
the same pattern exists for solo navigate rides and free rides.

## Why it happens

The ride summary is a `.sheet(item: $coordinator.finishedRide)` hosted on the ride HUD view
(`NavigateHUDView`, and the same shape in `RideHUDView`). Returning Home is a separate step in
`onDismiss` via `router.popToRoot()`.

Because the sheet is presented *by the HUD*, dismissing it slides the sheet down to reveal the
HUD underneath (that is just what a sheet dismiss does — it uncovers its presenter). Only after
the dismiss animation finishes does `onDismiss` fire and pop the stack to Home. So the sequence
the user sees is: summary slides down → HUD revealed → nav pops to Home. The middle step is the
flash.

The core tension: **to have Home behind the sheet on dismiss, the HUD must be gone before the
sheet dismisses — but the sheet is hosted by the HUD, so removing the HUD removes the sheet.**

## What was already tried (and why each failed) — don't repeat these

1. **Instant (non-animated) `popToRoot()` in `onDismiss`.** Removes the *second* animation (the
   pop) but not the flash: the sheet's own dismiss slide still uncovers the HUD before
   `onDismiss` ever fires. Partial at best.

2. **Mask overlay on the HUD gated by `finishedRide != nil`** (draw an opaque
   `AuraTheme.background` over the HUD while the summary is up). Fails because *dismissing the
   summary is `finishedRide → nil`* — the exact moment the mask's condition turns false. The mask
   vanishes precisely as the sheet starts sliding down, re-revealing the HUD. Any gate keyed on
   the sheet's own item can't survive its dismissal.

3. **Lift the sheet to the app root** (`RootView` in `AuraApp.swift`) via a
   `router.endedRide` item, and pop the HUD so the summary floats over Home. Correct idea, but a
   `.sheet` and a `NavigationStack` **path change fight each other**, in every ordering tried:
   - Set `endedRide` **and** `popToRoot()` in the same update → SwiftUI **drops** the sheet; it
     only appears after the next unrelated interaction (e.g. tapping "Where to").
   - Set `endedRide`, then `popToRoot()` a tick later → the sheet presents, then the path change
     **dismisses it** immediately (self-closing summary).
   - `popToRoot()` first, then `endedRide` a tick later → back to the sheet being **dropped**
     until the next interaction.

   The throughline: presenting/keeping a root-level sheet while the `NavigationStack` path
   mutates is unstable here. (Compare `AppRouter.replaceTopWithGroupRide`'s comment about
   `dismiss()` + `push()` racing into a blank destination — same family of nav/presentation
   race.)

## Candidate directions for a real fix (needs a design decision)

- **Summary as a pushed route instead of a sheet.** Make the finished ride a navigation
  destination and `popToRoot()` from it — `NavigationStack` animates the summary → Home directly,
  skipping the intermediate HUD entirely, with no sheet-vs-path race. This is likely the most
  robust option. Trade-off: it changes the summary's presentation feel from a slide-up sheet to a
  slide-in screen, for **all** ride types (solo navigate, free ride, group). That is a UX call
  for the PO, and `RideSummaryView`'s "Done" button / hero layout may want adjustment for a
  pushed context. `HistoryView` also presents `RideSummaryView` as a sheet — decide whether that
  path stays a sheet (it should; dismissing it correctly reveals History, no flash there).

- **Two-phase root presentation done carefully.** Keep the sheet, but pop to a fully-settled Home
  first and only then present — with enough separation (and possibly the sheet attached above the
  `NavigationStack` rather than on it) that the path mutation never overlaps the presentation.
  The attempts above suggest this is fiddly and easy to get subtly wrong; if pursued, verify each
  ordering on device, not just in the simulator.

- **A dedicated "ride ended" full-screen presenter** owned above the nav stack, decoupled from
  both the HUD and the path. More surface area, but sidesteps the sheet/nav interaction cleanly.

## Files

- `Aura/Sources/Ride/NavigateHUDView.swift` — navigate/group HUD; hosts the summary
  `.sheet(item: $coordinator.finishedRide, onDismiss: { router.popToRoot() })`.
- `Aura/Sources/Ride/RideHUDView.swift` — free-ride HUD; same summary-sheet-then-popToRoot shape.
- `Aura/Sources/Ride/RideSummaryView.swift` — the summary; "Done" calls `@Environment(\.dismiss)`.
- `Aura/Sources/History/HistoryView.swift` — also presents `RideSummaryView` (as a sheet over
  History; dismissing reveals History correctly, so no flash there — keep in mind if the
  presentation is refactored).
- `Aura/Sources/App/AuraApp.swift` (`RootView`) — the single `NavigationStack(path: $router.path)`.
- `Aura/Sources/App/AppRouter.swift` — `path`, `popToRoot()`; see the
  `replaceTopWithGroupRide` comment for a documented nav-path-race precedent.

## Suggested approach

Run this through the normal design flow (brainstorm the presentation model → confirm the
sheet-vs-pushed UX decision with the PO → plan → implement → whole-branch review), and
device-verify the end-to-end feel for **all three** ride types (solo navigate, free ride, group),
watching both the entrance and the dismiss. This is a shared, load-bearing flow — a regression
here breaks every ride's ending.
