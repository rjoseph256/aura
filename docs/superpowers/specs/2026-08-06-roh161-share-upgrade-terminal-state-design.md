# ROH-161 — the share-map upgrade needs a terminal state and a retry

Date: 2026-08-06. Branch `adaws96/roh-161-share-map-upgrade-fails-silently-one-attempt-no-terminal`.
Issue: https://linear.app/rohun/issue/ROH-161

> `humanizer` is mandated by `CLAUDE.md` for prose deliverables. It is **not installed on this
> machine**, so this document did not go through it. Recorded here rather than skipped silently.

## Problem

`RideSummaryView` shows the polyline fallback card immediately, then tries to upgrade it with a
real map. While that runs, "Adding your map…" appears. If the pipeline rejects, the hint
disappears and nothing else on screen changes — no message, no failed state, no way to ask again.

Two structural facts make it exactly one attempt per presentation:

- `.task` is guarded by `guard ride.stats != nil, shareImage == nil`
  (`RideSummaryView.swift:133`), and `shareImage` goes non-nil at `:141` the moment the fallback
  renders. A second run of that body is unreachable.
- There is no `scenePhase` handler, so nothing re-triggers on foreground.

Every reject path logs a distinct reason — style error, cancelled, belt timeout, degenerate
camera, render failed, acceptance failed, no strokeable path. All seven go to Console, for a
developer. The rider gets one vanishing spinner for all of them.

The second half is that `SharePipelineSlot`'s 20 s ceiling is a resource watchdog protecting an
app-lifetime singleton, and it is *also*, by accident, the only thing bounding how long a rider
stares at a spinner. ROH-126 already found the right separation one layer down —
"the ceiling has one legitimate job: stop making this caller wait. Freeing the slot is a
different job." The same split applies at the UI: the rider should stop waiting long before the
pipeline stops working.

## The finding that shapes the design

The issue's stated direction — a 6–8 s presentation deadline, after which the hint is replaced by
a terminal state — merges two failures that the pipeline's own timing numbers keep apart.

**The common failure is fast, not slow.** Offline with a remote style, `snapshotter.load`'s
completion errors and `loadStyle` rejects (`ShareMapSnapshotter.swift:285`), or the 4 s belt
(`:268`) trips with `isStyleLoaded` false. Either way the answer is known long before 6 s. A
deadline alone never fires on the case the issue is mostly about.

**A legitimately succeeding pipeline can outlast the deadline.** The style belt is 4 s (`:268`)
and the render belt is 6 s (`:352`), and they are sequential, so ~10–11 s is inside the *success*
envelope, not the failure one. A single state at 8 s saying "couldn't add the map" would
sometimes say it three seconds before the map appears.

**Retry means different things in the two cases.** After a reject, retry re-runs the whole
pipeline, and because there is deliberately no negative cache
(`ShareMapSnapshotter.swift:103-105`) it very often succeeds — the rider who failed on cellular at
the trailhead and taps Try again on wifi at home. While the pipeline is still running, retry hits
`slot.run` with the same key, joins the in-flight pipeline as a waiter
(`SharePipelineSlot.swift:90-96`), and buys nothing but a fresh 20 s ceiling.

So: two terminal states, and only one of them offers a retry.

## Goals

- A rider who loses the map is told so, on screen, instead of watching a spinner vanish.
- A rider who is told so can ask again, and asking again is a real second attempt.
- A rider whose pipeline is merely slow is not told it failed.
- The pocketed-phone case resolves itself without the rider having to notice a caption line.
- Every timing rule is unit-testable, in a target that has tests.

## Non-goals

- **Changing what Share does during the upgrade window.** ROH-126 §Share flow step 5 records
  this as decided: "a rider who shares within the first seconds… shares the polyline fallback
  card… the residue is accepted rather than blocking Share or adding retry UI." ROH-155 rev 2 was
  killed for silently reversing a recorded product decision. If Share should read "not ready yet",
  that is its own call, not a side effect of this one.
- **Touching the 0.8 s sleep, the prefetch, or the slot.** ROH-155 spent three revisions
  establishing why they are as they are; `docs/superpowers/specs/2026-07-31-share-prefetch-ownership-design.md`
  is the record. This design adds a layer above them and changes none of them.
- **A negative cache.** Its absence is what makes retry worth offering.
- **Lowering the 20 s ceiling.** It is correct for its job. This design stops the rider waiting
  on it; it does not stop the pipeline using it.

## Design

### The phase

```swift
public enum ShareUpgradePhase: Equatable, Sendable {
    case idle              // no upgrade is possible or none attempted
    case upgrading         // in flight, hint suppressed by the show-delay
    case upgradingVisible  // in flight, hint on screen
    case slow              // deadline passed, pipeline STILL RUNNING
    case unavailable       // the card has no map; retry offered
    case upgraded          // map landed
}
```

| Phase | Entered when | On screen | Retry offered |
|---|---|---|---|
| `idle` | no route, or the fallback render itself failed | nothing | no |
| `upgrading` | the upgrade request starts | nothing | no |
| `upgradingVisible` | +300 ms (unchanged show-delay) | spinner + "Adding your map…" | no |
| `slow` | +6 s, request not yet returned | spinner + "Still adding your map…" | no |
| `unavailable` | request returned without a map on the card | "Couldn't add the map" + **Try again** | **yes** |
| `upgraded` | the upgraded card was applied or deferred | nothing | no |

Legal transitions: `idle → upgrading → upgradingVisible → slow`, and from any of the three
in-flight phases to `unavailable` or `upgraded`. `unavailable → upgrading` is the retry.
**`slow → unavailable` and `slow → upgraded` are both reachable and both required** — `slow` is
explicitly not terminal for the pipeline, only for the rider's wait.

`idle` is load-bearing and not a placeholder. Two paths reach it and neither should show a failed
state:

- **No route** — `guard let request = ShareMapRequest(...)` at `RideSummaryView.swift:146`
  returns. There is no map to be had, so "Couldn't add the map" with a Try again that can never
  succeed would be a lie.
- **The fallback render failed** — `guard shareImage != nil` at `:145` returns and Share stays
  disabled (ROH-126's one promise). The rider's problem there is not the map, and an
  "Adding your map…" spinner under a dead Share button is the thing that guard exists to prevent.

### Why `unavailable` is defined by the card, not by the pipeline

`unavailable` is entered when the card ends up with no map — which is `raster(for:)` returning
nil **or** the raster arriving and the upgrade re-render failing
(`RideSummaryView.swift:187-189`; ROH-126's error table already says the fallback is kept there).
Both leave the rider in the same place, and retry is reasonable for both. Defining the phase by
the outcome the rider can see, rather than by which of seven internal rejects fired, is what
keeps this from needing to know about the pipeline's internals.

### Where the deadline is counted from

From the start of the upgrade request, and from nothing else. In particular **not** from the
entrance animation. ROH-155 rev 3 died partly on exactly that: "the entrance window" is 0.70 s
(count-up), 0.65 s (last staggered reveal), or **zero** under Reduce Motion, so a gate expressed
against it makes the rider who asked for no animation wait out an animation that does not exist.
This deadline has no Reduce Motion coupling by construction, and no coupling to `revealed`.

### The number: 6 s, and the flash it admits

6 s sits inside the range the issue proposed. Because `slow` makes no claim of failure, firing it
somewhat early costs nothing — its only job is to stop the rider believing nothing is happening.

**Known interaction, stated rather than hidden.** ROH-126's error table has a second offline case:
bundled `auraTerrain` loads fine and the tiles are absent, so the reject comes from the
interior-variance acceptance check — *after* the render belt. That path can return at roughly
6–7 s, i.e. just past a 6 s deadline, which puts the rider through
`upgradingVisible → slow → unavailable` with `slow` visible for well under a second.

This is accepted for three reasons, and it is a **named device-pass item** rather than a
prediction to be trusted:

1. All three phases occupy the same slot below Share with the same caption styling, so the
   change is a text swap, not a layout jump — the Done button does not move.
2. `slow` says "Still adding your map…", which is true at the instant it is shown.
3. The alternative — an 8 s deadline that lets that path reach `unavailable` directly — costs
   every genuinely-waiting rider two more seconds of silence, which is the primary complaint.

If the device pass shows the swap reads badly, the deadline is one constant and 8 s is the
fallback. The estimate above is derived from belt values in the source, not measured; measuring it
is step 1 of the device pass.

### Where the state machine lives

In **AuraKit**, as `ShareUpgradePresenter`, with the timing seam `SharePipelineSlot` already
established:

```swift
@Observable @MainActor
public final class ShareUpgradePresenter {
    public private(set) var phase: ShareUpgradePhase = .idle

    public init(hintDelay: Duration = .milliseconds(300),
                deadline: Duration = .seconds(6),
                sleep: (@Sendable (Duration) async -> Void)? = nil)

    public func begin()               // → .upgrading, arms both hops
    public func finish(gotMap: Bool)  // → .upgraded / .unavailable, cancels the hops
    public func noUpgradePossible()   // → .idle
}
```

The reason this is not five `@State` flags in the view: **the app target has no unit-test
target.** That is not a style preference — it is the documented reason the slot's watchdog defect
survived to a whole-branch review (`ShareMapSnapshotter.swift:122-128`: "the app target's lack of
any unit-test target put it out of reach of a test — which is where the review found the ceiling
arm clearing the slot out from under a live pipeline"). Every timing rule in this design becomes a
millisecond-scale test in `AuraKitTests` instead of a thing someone has to hold a phone to check.

Two constraints carried over from the neighbouring code:

- `sleep:` is `nil`-defaulted and the real closure is built **inside** the initializer, in the
  defining module — not an async closure default argument. ROH-110: such a default is duplicated
  into every module referencing the declaration and the copies can disagree about frame size,
  which aborts the process (`SharePipelineSlot.swift:59-67`).
- The two hops are one cancellable task with two sequential sleeps (300 ms, then the remainder to
  the deadline), not two tasks. `finish` cancels it. The existing hint task's `isCancelled` guard
  is load-bearing for the same reason it is today (`RideSummaryView.swift:174-184`): `try?`
  swallows the sleep's `CancellationError`, so a warm hit would otherwise flash the hint.

### Restructuring `.task`

The upgrade half moves out of `.task` into a function that both `.task` and Try again call.

- **`.task` keeps the 0.8 s sleep, untouched**, with all three of its documented jobs
  (`RideSummaryView.swift:148-172`).
- **Retry skips the sleep.** That sleep's third job is debouncing commitment of the exclusive
  process-wide slot against unattended History glances. An explicit tap on a screen the rider is
  looking at is not a glance — it is the one case where committing the slot immediately is exactly
  right. This is a deliberate divergence between the two callers and is the whole reason the
  extracted function takes the delay as a parameter rather than baking it in.
- **`ShareCardContent`, the file store, the title and `ShareMapRequest` are built once and held.**
  `routeSegments` maps every point of every segment and `ShareMapRequest.init` runs
  `ShareRouteGeometry.prepare`, both on the main actor. Rebuilding them per retry would put a
  whole-track walk on the main thread on every tap. `ShareMapRequest` is `Equatable, Sendable`
  (`ShareMapRequest.swift:13`), so holding it in `@State` is free.
- **The generation counter advances per attempt.** Today generation 0 is the fallback and 1 is the
  map (`ShareCardFileStore`, ROH-126 §Files). A retry that succeeds must not write to the same URL
  a live share-sheet consumer may still read lazily, so attempt *n* writes generation *n*. The
  per-presentation UUID directory already isolates presentations; this extends the same reasoning
  one level in.
- **Double-tap needs no separate guard.** Try again exists only in `unavailable`, and the tap
  moves the phase to `upgrading`, so the button removes itself before a second tap can land.
- **A retry landing while the share sheet is up reuses `applyOrDeferUpgrade`**
  (`RideSummaryView.swift:376`) unchanged. The swap latch already handles it and the device pass
  of 2026-07-31 is why it exists.

### Auto-retry once on foreground

`.onChange(of: scenePhase)`: on a transition *into* `.active` from anything else, if the phase is
`unavailable` and this presentation has not already auto-retried, retry once.

This is what actually closes the pocketed-phone half of the issue. Suspension parks the style
belt, the render belt and the ceiling so they all fire on resume and the pipeline rejects; without
this the rider unlocks to a caption they have to read and act on. With it, the rider who pockets
the phone at the trailhead and unlocks at home on wifi finds the map already there.

Bounded to exactly one per presentation, via a `didAutoRetry` flag, so a background/foreground
cycle cannot pump the exclusive slot. It fires only from `unavailable` — never from `slow`, where
it would join a live pipeline, and never from `idle`, where there is nothing to fetch. `onChange`
does not fire for the initial `.active`, so first presentation is unaffected.

### Copy

| Phase | Line |
|---|---|
| `upgradingVisible` | "Adding your map…" (unchanged) |
| `slow` | "Still adding your map…" |
| `unavailable` | "Couldn't add the map" + "Try again" |

Deliberately not alarming. The card is not broken: the rider has a working polyline card and
Share is enabled, which communicates "you can still share this" more credibly than a sentence
would. The wordier "Couldn't add the map — your card is still ready to share" was considered and
rejected as too long for a caption line on a screen whose headline is "Nice ride".

### Accessibility

- The three lines are one slot with `caption` weight and `AuraTheme.secondaryText(contrast)`,
  matching today's hint (`RideSummaryView.swift:107-114`).
- The transition into `unavailable` posts an accessibility announcement. Only that one: `slow`
  is a reassurance, and announcing every hop would be chatty on a screen a VoiceOver rider is
  already reading top to bottom.
- "Try again" is a real `Button` with an accessibility label naming what it retries
  ("Try again, add the map"), not a bare "Try again" whose antecedent is off-screen for anyone
  navigating by element.

## Files

| File | Change |
|---|---|
| `AuraCore/Sources/AuraKit/Sharing/ShareUpgradePhase.swift` | new — the enum |
| `AuraCore/Sources/AuraKit/Sharing/ShareUpgradePresenter.swift` | new — the driver + timing seam |
| `AuraCore/Tests/AuraKitTests/ShareUpgradePresenterTests.swift` | new — the timing rules |
| `Aura/Sources/Ride/RideSummaryView.swift` | `.task` split; phase-driven hint slot; Try again; `scenePhase` handler |

## Error handling

| Situation | Behavior |
|---|---|
| No route (`ShareMapRequest.init` returns nil) | `idle` — no hint, no terminal state, no retry |
| Fallback render fails | `idle`, Share disabled — unchanged from today |
| Pipeline rejects before the deadline (offline, remote style) | `upgradingVisible → unavailable`, Try again |
| Pipeline rejects after the deadline (offline, bundled style; tiles absent) | `slow → unavailable`, Try again, with the brief `slow` noted above |
| Pipeline succeeds after the deadline (slow link, 8–11 s) | `slow → upgraded`, card swaps, no failure ever claimed |
| Raster arrives, upgrade re-render fails | `unavailable` — fallback kept, Share still enabled |
| Retry while the first pipeline is still in flight | not reachable: Try again exists only in `unavailable` |
| Retry lands while the share sheet is up | held by `applyOrDeferUpgrade`, applied on dismissal |
| App backgrounded during the window | belts fire on resume → reject → `unavailable` → one auto-retry |
| View dismissed mid-upgrade | `.task` cancels; the `scenePhase` handler dies with the view |

## Testing

**Unit (`AuraKitTests`, hand-driven clock — the `SharePipelineSlotTests` pattern, where the
injected timer has never-fires and fires-at-once helpers):**

- the hint stays hidden before the show-delay and appears after it
- a result arriving before the show-delay never shows the hint at all (the warm-hit case)
- the deadline moves `upgradingVisible → slow` only while still in flight
- a reject before the deadline goes straight to `unavailable`, never through `slow`
- `slow → upgraded` and `slow → unavailable` are both reachable
- `finish` cancels the hop task, so a late deadline cannot resurrect `slow` over a terminal phase
- retry from `unavailable` re-enters `upgrading` and re-arms both hops
- `noUpgradePossible()` parks in `idle` and no hop ever fires

**Device pass (real device, per `CLAUDE.md` — a clean build proves nothing here):**

1. **Measure the offline-bundled-style reject.** The 6–7 s figure above is derived from belt
   values, not measured. If it lands well before 6 s the flash does not exist; if it lands well
   after, reconsider the constant.
2. Airplane mode at ride end → expect a fast `unavailable` with Try again.
3. Re-enable wifi, tap Try again → expect the map to land.
4. Pocket the phone during the upgrade window, unlock later on wifi → expect the map present
   without any interaction.
5. Retry while the share sheet is open → expect the sheet to stay up and the card to swap on
   dismissal.
6. VoiceOver: confirm the `unavailable` announcement fires and Try again reads sensibly.
7. Reduce Motion on: confirm the deadline behaves identically (it must — it is not coupled to the
   entrance).

This overlaps ROH-140 (the ROH-126 device-verification tail) on the same surface; items 5 and 7
plausibly close part of it.

## Risks

- **The `slow → unavailable` flash.** Named above, measured in device-pass item 1, one constant
  away from a fix.
- **Auto-retry commits the exclusive slot on foreground.** Bounded to one per presentation and
  gated on `unavailable`, so it cannot become the self-sustaining trickle that killed ROH-155
  rev 1. Worth re-checking at review that the bound is on the *presentation* and not the phase.
- **The extracted upgrade function now has two callers with different delay semantics.** That
  divergence is the point, but it is exactly the kind of thing that decays — the parameter is
  named for what it is (glance debounce), not for its value.
- **`@Observable` on a `@MainActor` class held in `@State`.** Standard, but this is the first
  observable presenter in this view, which already carries a share-sheet latch and five flags;
  the reviewer should check the two do not fight over who owns `shareImage`.
