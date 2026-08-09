# ROH-161 Share-Upgrade Terminal State — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the ride summary's vanishing "Adding your map…" spinner with a line that stays when the map does not arrive, and let a late success upgrade the card on its own.

**Architecture:** A total four-phase reducer in AuraKit owns what is on screen; the view feeds it six inputs and derives the spinner and the line from the phase. Because every input is legal in every phase and late or duplicate inputs are no-ops, task lifetime stops being a correctness concern — which matters because `onDisappear` is documented as unreliable on this hierarchy.

**Tech Stack:** Swift 6, SwiftUI, swift-testing (`import Testing`) in `AuraKitTests`, XCUITest for the device-facing checks.

**Spec:** `docs/superpowers/specs/2026-08-05-roh161-share-upgrade-terminal-state-design.md` (revision 4). Decision references below (D3, D7, D9…) point there.

---

## Prerequisite — base this on ROH-178

**Branch from `main` after `a1210df` ("fix(roh-178): ask whether the share sheet is up, not whether anything is") has merged.** Two reasons, the second is mechanical:

1. D9 makes the defer latch an input to the reducer. Before ROH-178, `shareSheetUp` stuck true for the History summary's entire lifetime, so `deferred` was a permanent state there rather than a transient one. The design tolerates that (D9a: it degrades honestly), but there is no reason to ship into it.
2. **Lint will fail otherwise.** `RideSummaryView.swift` is 515 lines before ROH-178 and 430 after (it extracted `SharePresentation` to its own file). This plan adds roughly 25 lines. On the ROH-178 base that is ~455, under the repo's 500-line limit; without it, ~540 and `scripts/lint.sh` fails with `file_length`.

Line numbers in this plan are **post-ROH-178**. Anchor edits on the quoted code, not the numbers.

---

## File Structure

| File | Responsibility |
| --- | --- |
| **Create** `AuraCore/Sources/AuraKit/Sharing/ShareUpgradePhase.swift` | The phase enum, the input enum, the total transition, the display derivation, and the deadline constant. Pure, `Sendable`, no SwiftUI. |
| **Create** `AuraCore/Tests/AuraKitTests/ShareUpgradePhaseTests.swift` | The D7 table asserted cell by cell, plus the derivation invariants. |
| **Modify** `Aura/Sources/Ride/RideSummaryView.swift` | Replace `isUpgrading`/`showHint` with `phase`/`hintDelayElapsed`; add the deadline task; make `applyOrDeferUpgrade` return its input; derive the display; render the line. |
| **Modify** `Aura/Sources/Ride/ShareCard/ShareMapSnapshotter.swift` | Correct the comment that says a nil is invisible in the UI by design — this feature deletes that premise (D10). |

Nothing else moves. No change to the provider API, the prefetch, the slot, or when a raster is requested (D11).

---

### Task 1: The reducer, and the table that is its specification

**Files:**
- Create: `AuraCore/Sources/AuraKit/Sharing/ShareUpgradePhase.swift`
- Test: `AuraCore/Tests/AuraKitTests/ShareUpgradePhaseTests.swift`

- [ ] **Step 1: Write the failing table test**

The whole point is that the table is asserted directly. A prose test ("every input yields a defined phase") passes for any total function, including two that revision 3 got wrong.

Create `AuraCore/Tests/AuraKitTests/ShareUpgradePhaseTests.swift`:

```swift
import Testing
@testable import AuraKit

/// The D7 table, asserted cell by cell. Revision 3 of the spec claimed the machine was total and
/// defined 16 of 28 cells; two of the gaps produced wrong on-screen states under the obvious rule.
/// So the table is the test, not a description of it.
struct ShareUpgradePhaseTests {
    typealias Phase = ShareUpgradePhase
    typealias Input = ShareUpgradeInput

    /// Every cell of D7's table. `expected == phase` means "no-op".
    static let table: [(phase: Phase, input: Input, expected: Phase)] = [
        // deadline reached
        (.upgrading,         .deadlineReached, .settledOnFallback),
        (.successPending,    .deadlineReached, .successPending),
        (.upgraded,          .deadlineReached, .upgraded),
        (.settledOnFallback, .deadlineReached, .settledOnFallback),
        // provider produced a raster
        (.upgrading,         .providerRaster,  .successPending),
        (.successPending,    .providerRaster,  .successPending),
        (.upgraded,          .providerRaster,  .upgraded),
        (.settledOnFallback, .providerRaster,  .settledOnFallback),
        // provider produced nothing
        (.upgrading,         .providerNothing, .settledOnFallback),
        (.successPending,    .providerNothing, .successPending),
        (.upgraded,          .providerNothing, .upgraded),
        (.settledOnFallback, .providerNothing, .settledOnFallback),
        // the upgrade render produced no card
        (.upgrading,         .renderNothing,   .upgrading),
        (.successPending,    .renderNothing,   .settledOnFallback),
        (.upgraded,          .renderNothing,   .upgraded),
        (.settledOnFallback, .renderNothing,   .settledOnFallback),
        // the card was applied to the screen
        (.upgrading,         .applied,         .upgraded),
        (.successPending,    .applied,         .upgraded),
        (.upgraded,          .applied,         .upgraded),
        (.settledOnFallback, .applied,         .upgraded),
        // the card was held behind a presented share sheet
        (.upgrading,         .deferred,        .successPending),
        (.successPending,    .deferred,        .successPending),
        (.upgraded,          .deferred,        .upgraded),
        (.settledOnFallback, .deferred,        .settledOnFallback)
    ]

    @Test(arguments: table)
    func tableCell(_ cell: (phase: Phase, input: Input, expected: Phase)) {
        #expect(cell.phase.applying(cell.input) == cell.expected)
    }

    /// Guards the table against the enums growing without it. A new phase or input that nobody adds
    /// rows for is a silent hole, which is exactly how revision 3 shipped 12 undefined cells.
    @Test func tableCoversEveryPhaseAndInputCombination() {
        #expect(Self.table.count == Phase.allCases.count * Input.allCases.count)
        for phase in Phase.allCases {
            for input in Input.allCases {
                #expect(Self.table.contains { $0.phase == phase && $0.input == input },
                        "no table row for (\(phase), \(input))")
            }
        }
    }

    // MARK: The cells that were bugs

    @Test func deadlineInSuccessPendingIsANoOp() {
        // The 6.9 s flash: a raster in hand must make the deadline irrelevant, or the line appears
        // for the length of a 1080x1350 render over a success that had already arrived.
        #expect(Phase.successPending.applying(.deadlineReached) == .successPending)
    }

    @Test func deadlineAfterSettlingOrUpgradingIsANoOp() {
        // This is what lets the deadline task's lifetime stop mattering (D7). `onDisappear` is
        // documented as unreliable here, so a late fire has to be harmless by construction.
        #expect(Phase.settledOnFallback.applying(.deadlineReached) == .settledOnFallback)
        #expect(Phase.upgraded.applying(.deadlineReached) == .upgraded)
    }

    @Test func aRasterDoesNotClearTheLineOnItsOwn() {
        // Revision 3 moved forward here. That cleared the line at the raster, before any card
        // existed, and if the render then deferred behind a sheet the rider was left with a
        // fallback card, no line, and nothing in flight.
        #expect(Phase.settledOnFallback.applying(.providerRaster) == .settledOnFallback)
    }

    @Test func aSecondRasterCannotPutTheSpinnerBackOverAFinishedCard() {
        #expect(Phase.upgraded.applying(.providerRaster) == .upgraded)
    }

    @Test func aDeferredCardHoldsSuccessPendingSoTheSpinnerStaysUp() {
        // D9: `deferred` means the card exists and is NOT on screen. Reporting `upgraded` here
        // would clear the line while the rider still has the generation-0 card.
        #expect(Phase.upgrading.applying(.deferred) == .successPending)
        #expect(Phase.successPending.applying(.deferred) == .successPending)
    }

    @Test func appliedFromSettledIsAutoApply() {
        #expect(Phase.settledOnFallback.applying(.applied) == .upgraded)
    }

    @Test func aFailedUpgradeRenderSettlesOnTheFallback() {
        // A raster that renders no card leaves generation 0 on screen, so the phase must say so.
        #expect(Phase.successPending.applying(.renderNothing) == .settledOnFallback)
    }

    @Test func repeatedAndOutOfOrderInputsDoNotProduceAWrongPhase() {
        #expect(Phase.upgrading.applying(.applied).applying(.applied) == .upgraded)
        #expect(Phase.upgrading.applying(.deadlineReached).applying(.deadlineReached) == .settledOnFallback)
        // A reject followed by a late raster must not reopen the spinner.
        #expect(Phase.upgrading.applying(.providerNothing).applying(.providerRaster) == .settledOnFallback)
    }

    // MARK: Display derivation (D9a — where the last hole was)

    @Test(arguments: Phase.allCases)
    func spinnerAndLineAreNeverBothShown(_ phase: Phase) {
        #expect(!(phase.wantsSpinner && phase.wantsSettledLine))
    }

    @Test(arguments: Phase.allCases)
    func somethingIsShownWheneverWorkIsOutstanding(_ phase: Phase) {
        let outstanding = phase == .upgrading || phase == .successPending
        if outstanding { #expect(phase.wantsSpinner) }
    }

    @Test func settledShowsTheLineAndNoSpinner() {
        #expect(Phase.settledOnFallback.wantsSettledLine)
        #expect(!Phase.settledOnFallback.wantsSpinner)
    }

    @Test func upgradedShowsNeither() {
        #expect(!Phase.upgraded.wantsSpinner)
        #expect(!Phase.upgraded.wantsSettledLine)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd AuraCore && swift test --filter ShareUpgradePhaseTests
```

Expected: FAIL to compile — `cannot find 'ShareUpgradePhase' in scope`.

- [ ] **Step 3: Write the implementation**

Create `AuraCore/Sources/AuraKit/Sharing/ShareUpgradePhase.swift`:

```swift
import Foundation

/// What the ride summary is showing about its share-card map upgrade (ROH-161).
///
/// The upgrade has three outcomes a rider can perceive — a map arrived, a map did not, or one is
/// still coming — and before this type the third and second were indistinguishable: the
/// "Adding your map…" hint simply vanished and nothing replaced it.
///
/// **The load-bearing property is that `applying(_:)` is total.** Every input is legal in every
/// phase, and a late or duplicate input is a no-op. That is what takes task lifetime off the
/// correctness path: the deadline lives in an unstructured `Task` whose cancellation cannot be
/// relied on (`RideHUDView.swift` records that `onDisappear` "can fire without the rider asking for
/// anything"), so a deadline that fires after the screen settled has to be harmless by
/// construction rather than by being cancelled in time.
///
/// Lives in AuraKit rather than beside the view because the app target has no unit-test target.
/// `ShareMapSnapshotter` records what that cost this exact subsystem: the pipeline slot "used to
/// live inline here, where the app target's lack of any unit-test target put it out of reach of a
/// test — which is where the review found the ceiling arm clearing the slot out from under a live
/// pipeline."
public enum ShareUpgradePhase: Equatable, Sendable, CaseIterable {
    /// Waiting on the provider. The spinner shows once the show-delay has elapsed.
    case upgrading
    /// A raster is in hand; its card is not on screen yet — either still rendering, or rendered and
    /// held behind a presented share sheet. The spinner stays up, because nothing has arrived for
    /// the rider yet.
    case successPending
    /// A generation-1 card is on screen. Nothing is shown.
    case upgraded
    /// The rider has been told the card carries a simple map. The line shows.
    case settledOnFallback

    /// How long the rider waits before `settledOnFallback`.
    ///
    /// Its only job is to bound the wait, and it is deliberately none of the three existing bounds:
    /// the slot's 20 s ceiling stops *one caller* waiting on one pipeline, and the 4 s style and 6 s
    /// render belts each bound one SDK call. Measured context: ~1.5 s on device over wifi, 2.18 s
    /// under contention, and ~8 s on a *cold simulator* — so on a cold simulator the line will often
    /// appear ahead of a success that was coming, which is a simulator artefact and not a device
    /// claim (spec D3).
    ///
    /// `ContinuousClock` at the call site, matching the ceiling: a locked phone should not hold the
    /// line off.
    public static let presentationDeadline: Duration = .seconds(7)

    /// The whole state machine. See the spec's D7 for the table this implements, and
    /// `ShareUpgradePhaseTests` for the table asserted cell by cell.
    ///
    /// Terminal is reached by *input*, not by phase — the deadline settles only from `upgrading`,
    /// while a failed render settles only from `successPending`. Scoping it by phase instead (as
    /// revision 2 of the spec did) forbids the render-failure transition it also requires.
    public func applying(_ input: ShareUpgradeInput) -> ShareUpgradePhase {
        switch (self, input) {
        // Nothing is coming, or the rider has waited long enough.
        case (.upgrading, .deadlineReached),
             (.upgrading, .providerNothing),
             (.successPending, .renderNothing):
            return .settledOnFallback

        // Something arrived but the rider cannot see it yet.
        case (.upgrading, .providerRaster),
             (.upgrading, .deferred):
            return .successPending

        // `applied` is emitted only where `shareImage` is actually written, so it is the one input
        // that may move to `upgraded` from anywhere — including `settledOnFallback`, which is
        // auto-apply.
        case (_, .applied):
            return .upgraded

        // Everything else is a late or duplicate input. Holding still is the correct answer, and it
        // is what makes the deadline task's lifetime a performance question rather than a
        // correctness one.
        default:
            return self
        }
    }

    /// Whether a spinner belongs on screen — subject to the view's separate show-delay.
    ///
    /// `successPending` counts: a raster in hand is not a card on screen, and a card held behind a
    /// share sheet is not one either. Clearing the spinner there is the defect D9 exists to prevent.
    public var wantsSpinner: Bool { self == .upgrading || self == .successPending }

    /// Whether the terminal line belongs on screen.
    public var wantsSettledLine: Bool { self == .settledOnFallback }
}

/// What the view tells the phase machine. Six inputs, and deliberately not seven: a rendered card
/// goes straight to the view's apply-or-defer decision, so the machine only ever hears the
/// *outcome* of that decision rather than the render's own success.
public enum ShareUpgradeInput: Equatable, Sendable, CaseIterable {
    /// The presentation deadline elapsed.
    case deadlineReached
    /// `raster(for:)` returned an image.
    case providerRaster
    /// `raster(for:)` returned nil — rejected, or this caller stopped waiting. The two are
    /// indistinguishable through the current provider API; distinguishing them is ROH-176.
    case providerNothing
    /// The generation-1 card failed to render, encode or write.
    case renderNothing
    /// A card was written to `shareImage` and is on screen.
    case applied
    /// A card exists but was held in `deferredUpgrade` because a share sheet is presented.
    case deferred
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd AuraCore && swift test --filter ShareUpgradePhaseTests
```

Expected: PASS, 24 table cells plus the named cases.

- [ ] **Step 5: Run the whole package suite and lint**

```bash
cd AuraCore && swift test
```
Expected: PASS (876+ tests before this task's additions).

```bash
./scripts/lint.sh
```
Expected: `0 violations, 0 serious`.

- [ ] **Step 6: Commit**

```bash
git add AuraCore/Sources/AuraKit/Sharing/ShareUpgradePhase.swift \
        AuraCore/Tests/AuraKitTests/ShareUpgradePhaseTests.swift
git commit -m "feat(roh-161): a total phase machine for the share-map upgrade

Four phases, six inputs, and every cell of the table asserted directly rather
than described. Totality is the load-bearing property: a late or duplicate
input is a no-op, so the deadline task's lifetime stops being a correctness
concern.

Three cells were bugs earlier revisions of the spec shipped. A raster arriving
after the rider settled does NOT clear the line — only an applied card does,
because clearing at the raster left a fallback card with no line and nothing in
flight when the render then deferred behind a share sheet. A deferred card
holds successPending so the spinner stays up. And the deadline is a no-op once
a raster is in hand, which kills a line flashing over a success that had
already arrived."
```

---

### Task 2: Wire the view to the machine

**Files:**
- Modify: `Aura/Sources/Ride/RideSummaryView.swift`

No new unit tests here — this layer has no test target, which is why Task 1 exists. It is verified by Task 4's device pass.

- [ ] **Step 1: Replace the two display flags with the phase**

Find:

```swift
    /// True while the map upgrade is in flight (raster request + re-render); drives the hint.
    @State private var isUpgrading = false
    /// Shown 300 ms into an upgrade so a warm cache hit never flashes it.
    @State private var showHint = false
```

Replace with:

```swift
    /// What the upgrade is showing (ROH-161). `nil` until the upgrade actually starts — no route,
    /// no stats, no fallback card, or a History glance cancelled at the 0.8 s sleep all return
    /// before the machine exists, and the spec is explicit that "absent" is a precondition rather
    /// than a phase.
    @State private var phase: ShareUpgradePhase?
    /// Whether the hint's 300 ms show-delay has elapsed. The one view-local display flag left: the
    /// phase does not change at t+0.3 s, so this cannot be derived from it without a second timer
    /// and a second late-fire hazard. Never written by the reducer.
    @State private var hintDelayElapsed = false
    /// The presentation deadline. Held so a warm hit can cancel it; correctness does not depend on
    /// that, because a late `deadlineReached` is a no-op in every phase it can reach.
    @State private var deadline: Task<Void, Never>?
```

- [ ] **Step 2: Feed the machine from the upgrade task**

Find, in the `.task`:

```swift
            guard !Task.isCancelled else { return }
            isUpgrading = true
```

Replace with:

```swift
            guard !Task.isCancelled else { return }
            phase = .upgrading
            // Deliberately not cancelled on dismissal, and it does not need to be: `applying` is
            // total, so a deadline that fires into a settled or upgraded phase is a no-op. The
            // `isCancelled` re-check is belt-and-braces — `try?` swallows the sleep's
            // CancellationError, the same trap the hint task below documents.
            deadline = Task {
                try? await Task.sleep(for: ShareUpgradePhase.presentationDeadline)
                guard !Task.isCancelled else { return }
                phase = phase?.applying(.deadlineReached)
            }
```

Then find:

```swift
            let hint = Task {
                try? await Task.sleep(for: .seconds(0.3))
                guard !Task.isCancelled, isUpgrading else { return }
                showHint = true
            }
```

Replace with:

```swift
            let hint = Task {
                try? await Task.sleep(for: .seconds(0.3))
                guard !Task.isCancelled else { return }
                // No phase check needed any more: the spinner is derived, so if the phase has
                // already moved to `upgraded` or `settledOnFallback` this flag shows nothing. That
                // is what deleting the imperative `showHint = false` buys — the warm-cache flash
                // the old `isUpgrading` guard existed to prevent is now impossible by derivation.
                hintDelayElapsed = true
            }
```

Then find the tail:

```swift
            let raster = await shareMap.provider.raster(for: request)
            hint.cancel()
            if let raster, !Task.isCancelled,
               let upgraded = await RideCardRenderer.make(content, mapImage: raster, title: title,
                                                          writeTo: fileStore.url(generation: 1)) {
                // Never assign nil over a working fallback — and never swap the item out from
                // under a presented share sheet (see `applyOrDeferUpgrade`).
                applyOrDeferUpgrade(upgraded)
            }
            isUpgrading = false
            showHint = false
        }
```

Replace with:

```swift
            let raster = await shareMap.provider.raster(for: request)
            hint.cancel()
            guard let raster else {
                // Rejected, or this caller stopped waiting — the provider cannot tell us which
                // (ROH-176). Either way the rider gets the line, at the moment we learn it rather
                // than at the deadline.
                phase = phase?.applying(.providerNothing)
                deadline?.cancel()
                return
            }
            phase = phase?.applying(.providerRaster)
            // A dismissed view feeds nothing further: nothing failed, we abandoned. Feeding
            // `renderNothing` here would settle a phase nobody is looking at.
            guard !Task.isCancelled else { return }
            if let upgraded = await RideCardRenderer.make(content, mapImage: raster, title: title,
                                                         writeTo: fileStore.url(generation: 1)) {
                // The input comes from the same expression that writes `shareImage`, so the phase
                // cannot disagree with what is on screen (D9).
                phase = phase?.applying(applyOrDeferUpgrade(upgraded))
            } else {
                phase = phase?.applying(.renderNothing)
            }
            deadline?.cancel()
        }
```

- [ ] **Step 3: Make `applyOrDeferUpgrade` return its input**

Find:

```swift
    private func applyOrDeferUpgrade(_ upgraded: RideShareImage) {
        if shareSheetUp {
            deferredUpgrade = upgraded
        } else {
            shareImage = upgraded
        }
    }
```

Replace with:

```swift
    /// Applies the upgrade, or holds it if a share sheet is presented — and **returns which it
    /// did**, so the phase machine hears it from the same expression that writes `shareImage`.
    ///
    /// That return is the point. The phase is a second copy of a fact whose ground truth is
    /// `shareImage`, and no `AuraKitTests` test can observe the two diverging. Returning the input
    /// makes divergence unrepresentable instead of a convention someone has to remember: a caller
    /// cannot report `applied` for a write that went to `deferredUpgrade`.
    private func applyOrDeferUpgrade(_ upgraded: RideShareImage) -> ShareUpgradeInput {
        if shareSheetUp {
            deferredUpgrade = upgraded
            return .deferred
        }
        shareImage = upgraded
        return .applied
    }
```

- [ ] **Step 4: Route the deferred release through the same writer**

Find, at the end of `beginShareSheetWatch`:

```swift
            shareSheetUp = false
            if let deferredUpgrade {
                shareImage = deferredUpgrade
                self.deferredUpgrade = nil
            }
```

Replace with:

```swift
            shareSheetUp = false
            if let held = deferredUpgrade {
                // Back through `applyOrDeferUpgrade`, not a direct write: `shareSheetUp` is false
                // now, so it takes the apply branch and returns `.applied`. One writer of
                // `shareImage`, one source of the phase input (D9).
                self.deferredUpgrade = nil
                phase = phase?.applying(applyOrDeferUpgrade(held))
            }
```

- [ ] **Step 5: Build**

Delegate to the builder agent so the log does not fill the session:

```
Agent(subagent_type: "apple-platform-build-tools:builder"):
  Build the Aura scheme for the iOS Simulator and report only failures.
  cd Aura && xcodegen generate, then build for
  'platform=iOS Simulator,id=<booted iPhone>'.
```

Expected: builds clean. The view still shows nothing new — Task 3 renders the line.

- [ ] **Step 6: Commit**

```bash
git add Aura/Sources/Ride/RideSummaryView.swift
git commit -m "feat(roh-161): drive the summary's upgrade display from the phase machine

Replaces isUpgrading and showHint with a phase plus a show-delay flag, adds the
presentation deadline, and deletes the imperative clears that ran the moment
applyOrDeferUpgrade returned — including on its deferred branch, which is what
would have left a deferred card showing no spinner and no line.

applyOrDeferUpgrade now returns the input it caused, and the deferred release
goes back through it, so shareImage has one writer and the phase cannot claim a
card the rider cannot see."
```

---

### Task 3: Render the terminal line

**Files:**
- Modify: `Aura/Sources/Ride/RideSummaryView.swift`

- [ ] **Step 1: Derive both display facts from the phase**

Find:

```swift
                    if showHint {
                        HStack(spacing: AuraTheme.Spacing.xs) {
                            ProgressView()
                            Text("Adding your map…")
                        }
                        .font(.caption)
                        .foregroundStyle(AuraTheme.secondaryText(contrast))
                    }
```

Replace with:

```swift
                    // Both facts are derived from the phase, and they are mutually exclusive by
                    // construction — `ShareUpgradePhaseTests` asserts that for every phase, so a
                    // spinner can never appear beside the line.
                    if phase?.wantsSettledLine == true {
                        // An observation, not an error and not an offer. The card is complete and
                        // shareable; the map is an upgrade that did not land. So no destructive
                        // colour, no warning glyph, and no promise of an action — there is no retry
                        // in this phase (that is ROH-176), and copy that implied one would be a lie.
                        Text("Your card uses a simple map")
                            .font(.caption)
                            .foregroundStyle(AuraTheme.secondaryText(contrast))
                    } else if phase?.wantsSpinner == true, hintDelayElapsed {
                        HStack(spacing: AuraTheme.Spacing.xs) {
                            ProgressView()
                            Text("Adding your map…")
                        }
                        .font(.caption)
                        .foregroundStyle(AuraTheme.secondaryText(contrast))
                    }
```

> **The copy is provisional.** The spec fixes the line's *job* (D2) and leaves its words as open question 1. "Your card uses a simple map" states what the rider has without apologising or promising. Settle it on the device pass.

- [ ] **Step 2: Build and look at it**

Build via the builder agent, then run the app on a simulator with a recorded ride and confirm the line renders where the hint did.

- [ ] **Step 3: Commit**

```bash
git add Aura/Sources/Ride/RideSummaryView.swift
git commit -m "feat(roh-161): show a line that stays when no map arrives

Replaces the vanishing spinner with an observation about what the rider has.
Both the spinner and the line are derived from the phase and are mutually
exclusive by construction, which the reducer tests assert for every phase."
```

---

### Task 4: Correct the two comments this feature falsifies

**Files:**
- Modify: `Aura/Sources/Ride/ShareCard/ShareMapSnapshotter.swift`
- Modify: `Aura/Sources/Ride/RideSummaryView.swift`

Small, and worth its own task so it is not lost: both comments assert things that are now false, and this repo treats a stale comment as a defect.

- [ ] **Step 1: Fix the "invisible by design" premise**

In `ShareMapSnapshotter.swift`, the doc above the reject logging says a nil is "invisible in the UI by design." ROH-161 deletes that premise. Replace that clause with a statement that the UI now says *something* on a nil — a line rather than silence — while the reason stays in the log because the rider can act on none of the nine.

- [ ] **Step 2: Fix "Share is enabled from the first frame"**

In `RideSummaryView.swift`, the comment above the fallback render claims Share is enabled from the first frame. It is not: `shareImage` is assigned inside the `.task` after `Task.yield()` and an awaited render, so Share is disabled for the first several frames — and stays disabled forever if that render fails (ROH-177). Correct it to say Share is enabled *as soon as the fallback card exists*.

- [ ] **Step 3: Lint and commit**

```bash
./scripts/lint.sh
git add Aura/Sources/Ride/ShareCard/ShareMapSnapshotter.swift Aura/Sources/Ride/RideSummaryView.swift
git commit -m "docs(roh-161): two comments this feature falsifies

A pipeline nil is no longer invisible in the UI — that was the premise ROH-161
deletes. And Share is not enabled from the first frame: shareImage is assigned
inside the .task after an awaited render, and stays nil forever if that render
fails (ROH-177)."
```

---

### Task 5: Device pass

**Files:** none — this is verification, and per CLAUDE.md a clean build proves none of it.

Run on a real device where the item says device; the simulator is honest for the first two.

- [ ] **Airplane mode at ride end.** Line appears and *stays*. Share still works and sends the polyline card.
- [ ] **Lock through the entire window.** Unlock to the line on screen, no spinner. This is the ceiling's `ContinuousClock` expiring and cancelling the pipeline (D6) — expect no map, and confirm the line rather than a spinner.
- [ ] **Swap while the share sheet is open**, both presentations — pushed and the History sheet. Present the sheet, land an upgrade under it, confirm the sheet neither dismisses nor changes payload, **and** that the deferred upgrade is applied on dismissal. Auto-apply makes this routine rather than rare, and ROH-178 is what made the History half work at all.
- [ ] **A healthy wifi ride.** The line must never appear — the upgrade lands in ~1.5 s, well inside 7 s.
- [ ] **Does 7 s feel right?** Open question 2. On a cold simulator the line will appear ahead of successes; that is expected and not the signal.
- [ ] **Does the copy read right on glass?** Open question 1, and the words in Task 3 are provisional.
- [ ] **Is the moving `Done` button a mis-tap hazard?** The line appears above it at 7 s and auto-apply removes it later, moving `Done` twice.

- [ ] **Record the outcome** as a comment on ROH-161, including anything that did not reproduce. The ROH-126 device-pass commit is the model: it said plainly which paths it did *not* exercise, and that honesty is why ROH-178 was findable.

---

## Out of scope — do not add these while in here

Retry and the typed provider outcome (ROH-176). The disk-cache re-probe and the ceiling-nil-with-a-cached-raster case (ROH-176). The fallback-render silent failure (ROH-177). The 2 s one-shot presentation wait (still open on ROH-178). The 20 s ceiling. Blocking or gating Share. Negative caching. Naming reject reasons in the UI. Any change to when a raster is requested, to the prefetch, or to slot ownership (D11 — that is ROH-155, closed won't-do).
