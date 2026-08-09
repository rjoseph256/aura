# ROH-161 — the share-map upgrade needs a terminal state and a retry

Date: 2026-08-06. Branch `adaws96/roh-161-share-map-upgrade-fails-silently-one-attempt-no-terminal`.
Issue: https://linear.app/rohun/issue/ROH-161

**Revision 3.** Revision 1 went through the three-reviewer adversarial gate and did not survive it;
the record of what was wrong is at the end, under §What revision 1 got wrong, because most of it was
wrong in ways the next person to touch this surface would repeat. Revision 2 rebuilt it around
outcome-typed results. Revision 3 replaced the terminal state's error framing with an offer, after
an earlier ungated ROH-161 draft was found on branch
`adaws96/roh-161-share-map-upgrade-silent-failure` that had reached that conclusion independently
of the product reviewer — see §Copy.

That draft is a second, superseded spec for this issue. It should be deleted, or its branch closed,
before this one merges; two specs for one issue is how a decision gets re-litigated by whoever finds
the wrong one first.

> `humanizer` is mandated by `CLAUDE.md` for prose deliverables. It is **not installed on this
> machine**, so this document did not go through it. Recorded here rather than skipped silently.

## Problem

`RideSummaryView` shows the polyline fallback card immediately, then tries to upgrade it with a
real map. While that runs, "Adding your map…" appears. If the pipeline rejects, the hint
disappears and nothing else on screen changes — no message, no failed state, no way to ask again.

Two structural facts make it one attempt per presentation:

- `.task` is guarded by `guard ride.stats != nil, shareImage == nil` (`RideSummaryView.swift:133`),
  and `shareImage` goes non-nil at `:141` as soon as the fallback renders. (Strictly, a re-appear
  could re-run the body if the *fallback* render itself returned nil — but that is the path where
  Share is disabled and there is no card at all, so it is not the case this issue is about.)
- There is no `scenePhase` handler anywhere in the view, so nothing re-triggers on foreground.

Every reject path logs a reason to Console, for a developer. The rider gets one vanishing spinner
for all of them. (Nine distinct reject strings, not seven — `ShareMapSnapshotter.swift:225` alone
covers four paths in one message, and the ceiling case logs no reject line at all, only
`onCeiling`'s `log.info`.)

## The finding that shapes this design

**`raster(for:)` returning nil does not mean the pipeline failed.** The slot was deliberately
rewritten so that it doesn't. `SharePipelineSlot.swift:97-111` is explicit — a waiter's ceiling
"unblocks THIS caller and nothing else… it must not clear the slot, **because the pipeline is
still alive**." The owner's ceiling cancels but does not free the slot (`:129-134`), and
cancellation is not honoured past the render anyway (`ShareMapSnapshotter.swift:227-230`).

So one nil carries three different situations, and they call for three different responses:

| What happened | Is the pipeline dead? | Is a retry a real second attempt? |
|---|---|---|
| The pipeline ran and produced no acceptable map | yes | **yes** — no negative cache, so it re-runs in full |
| A ceiling fired while this caller waited | **no** | no — it re-joins the live pipeline, or warm-hits if it has since finished |

At ride end the summary is specifically the **waiter**: the HUD prefetch claims the slot at
+0.7 s (`ShareMapRasterProviding.swift:44-56`) and the ROH-155 record says so outright. So the
ceiling case is not a corner — it is the ride-end shape.

This is not a theoretical distinction. `AuraCore/Tests/AuraKitTests/SharePipelineSlotTests.swift:261`
is a checked-in test named `testSameKeyRetryDuringUnwindJoinsTheDyingPipeline`, asserting "the
retry inherits the cancelled pipeline's nil" and "does not run a second pipeline for a live key."

**A design that offers a retry has to know which nil it got.** That is the seam change below, and
everything else in this document follows from it.

## Goals

- A rider who loses the map is told so, instead of watching a spinner vanish.
- A rider who is told so can ask again, and the app only promises a second attempt when it can
  deliver one.
- A rider whose pipeline is merely slow is never told it failed.
- The automatic recovery fires on a signal that actually correlates with the failure's cause.
- Every timing rule is unit-testable in a target that has tests, and `begin`/`finish` pairing is
  structurally impossible to get wrong.

## Non-goals

- **Changing Share's behavior during the upgrade window.** ROH-126 §Share flow step 5 accepted
  that a rider sharing in the first seconds gets the fallback card. That stays. See §The ROH-126
  clause below — this design does *not* claim ROH-126 settled it.
- **Touching the 0.8 s sleep, the prefetch, or the slot's policy.** The slot's *return type*
  changes (below); none of its behavior does.
- **A negative cache.** Its absence is what makes retry meaningful.
- **Lowering the 20 s ceiling.** It is correct for its job.
- **History.** See §Scope.

## Scope: the ride-end presentation only

`RideSummaryView` is also the History detail sheet (`HistoryView.swift:53`). The terminal state
and the retry are **ride-end only**; History keeps today's silent behavior exactly.

Because there is no negative cache, every History open of a ride re-runs the pipeline. Offline,
that means a rider paging through old rides to look at their stats would otherwise collect a
"Couldn't add the map" line on every one of them — for a share card they did not ask for and
cannot see on that screen. ROH-126 already designated the History reopen as the recovery path
("a later History open upgrades"); making it also the complaint path inverts that.

Discriminated by an explicit `presentation: .rideEnd | .history` parameter, not by the nullness of
`onDone` (`RideSummaryView.swift:13-14`), which happens to correlate today but is a callback, not
a policy flag. Two call sites.

> **Assumption, overturnable.** This scope was recommended and not explicitly ratified. If the
> terminal state should appear in History too, the change is the parameter's default and one line
> in §Phases; nothing else in this design depends on it.

## Design

### The seam: outcomes instead of nil

`SharePipelineSlot.run` already knows which case it is in — it just discards the distinction at the
return. Give it back:

```swift
public enum SlotOutcome<Value: Sendable>: Sendable {
    case finished(Value?)   // the pipeline ran to completion; nil means it produced nothing
    case stoppedWaiting     // a ceiling fired; the pipeline may still be alive and hold the slot
}
```

`run` returns `SlotOutcome<Value>`. **No behavior changes** — the three existing `return nil` sites
map to `.stoppedWaiting`, `.stoppedWaiting`, and `.finished(nil)` respectively, and every existing
policy (who cancels, who frees the slot, what the ceiling does) is untouched. This is additive
information, which is what makes it safe to do to a type this load-bearing.

`ShareMapRasterProviding` follows:

```swift
enum ShareMapOutcome: Sendable {
    case map(UIImage)
    case rejected         // the pipeline ran and produced no acceptable map
    case stoppedWaiting   // a ceiling fired; a retry may re-join rather than restart
}

func raster(for request: ShareMapRequest) async -> ShareMapOutcome
```

Cache hit → `.map`. `.finished(image)` → `.map`. `.finished(nil)` → `.rejected`.
`.stoppedWaiting` → `.stoppedWaiting`. The `?? nil` for a deallocated `self`
(`ShareMapSnapshotter.swift:155-157`) → `.rejected`.

The prefetch discards its result already (`_ = await provider.raster(...)`) and is unaffected.

### Phases

```swift
public enum ShareUpgradePhase: Equatable, Sendable {
    case idle              // no upgrade possible, or none attempted
    case upgrading         // in flight, indicator suppressed by the show-delay
    case upgradingVisible  // in flight, indicator on screen
    case slow              // past the presentation deadline, request still outstanding
    case unavailable(Retryability)   // the card has no map
    case upgraded(confirming: Bool)  // map applied; `confirming` only after an explicit retry
}

public enum Retryability: Equatable, Sendable {
    case freshAttempt   // from .rejected — retry re-runs the pipeline
    case mayRejoin      // from .stoppedWaiting — retry warm-hits or re-joins the live pipeline
}
```

| Phase | Entered when | On screen | Try again |
|---|---|---|---|
| `idle` | no route, or the fallback render failed | nothing | no |
| `upgrading` | attempt starts (first attempt only) | nothing | no |
| `upgradingVisible` | first attempt +300 ms; **immediately** on a retry | spinner + "Adding your map…" | no |
| `slow` | +6 s, request still outstanding | spinner + "Still adding your map…" | no |
| `unavailable(.freshAttempt)` | `.rejected` | "Add the map" (button only) | **yes** |
| `unavailable(.mayRejoin)` | `.stoppedWaiting` | "Add the map" (button only) | **yes** |
| `upgraded(confirming: true)` | map applied after an explicit retry | "Map added" for ~2 s, then nothing | no |
| `upgraded(confirming: false)` | map applied on the first attempt | nothing | no |

`idle` is load-bearing, not a placeholder. Two paths reach it and neither may show a failure:
**no route** (`ShareMapRequest.init` returns nil, `RideSummaryView.swift:146`) — a Try again that
can never succeed would be a lie; and **the fallback render failed** (`:145`), where Share is
disabled and the rider's problem is not the map.

Both `unavailable` cases show the same line and offer the same button. They differ in **what the
app is allowed to do automatically** (below) and in what the spec promises: from `.mayRejoin` a
tap may warm-hit instantly (the pipeline finished after we stopped waiting — `raster(for:)` probes
the disk cache before the slot, `ShareMapSnapshotter.swift:143-151`) or re-join for up to another
ceiling. That is still the only route to the map from there, and the rider asked for it. What the
distinction forbids is doing that *without* being asked.

### The presentation deadline: 6 s, and what it is for

The ceiling is 20 s and nobody waits 20 s standing over their bike. That is the entire
justification, and it needs no measurement to stand up. `slow` does not stop the rider waiting —
nothing here does, and the slot's own doc notes the wait is not even bounded by one ceiling
(`SharePipelineSlot.swift:24-27`: N different-key pipelines cost a waiter up to N × ceiling). What
`slow` does is stop the rider believing the app has forgotten about them.

6 s is well past the ~1.5 s the upgrade takes on device (`RideSummaryView.swift:375`, and the
ROH-155 record's correction of the same number) and well before the ceiling.

Counted from the start of the attempt and from nothing else — **not** from the entrance animation.
ROH-155 rev 3 died partly on that: the entrance window is 0.70 s, 0.65 s, or **zero** under Reduce
Motion, so any gate expressed against it makes the rider who asked for no animation wait out an
animation that does not exist. No Reduce Motion coupling, by construction.

### Minimum dwell, so nothing flashes

A reject can land at essentially any time up to ~10 s: the style belt caps at 4 s (`:268`) and the
render belt at 6 s (`:352`), and they are caps, not durations — if the render belt fires,
`renderMapRasterWithChrome` returns nil at `:373` and `runPipeline` rejects at `:222-226` without
ever reaching acceptance. So there is no deadline value that cleanly separates rejects from the
deadline; some rejects will always land just after it.

Rather than tune a constant against that, the presenter enforces a **minimum visible duration of
1 s on any indicator it shows**. `upgradingVisible` and `slow` each stay put for at least 1 s
before any transition out of them is applied. This is a rule in a tested type, not a number to
re-tune per device.

It also fixes the retry case: a retry whose raster is already cached warm-hits in milliseconds,
and without a dwell the rider would tap a button and see `unavailable → upgrading → unavailable`
with no visible change at all.

### The show-delay applies to the first attempt only

The 300 ms show-delay exists so a warm cache hit never flashes the hint (ROH-126 §Share flow
step 4; `RideSummaryView.swift:174-184`). A retry is not that case — the rider just pressed a
button and needs to see that it registered. **A retry shows its indicator immediately.**

### The presenter, and why `begin`/`finish` cannot be unpaired

In **AuraKit**, because the app target has no unit-test target — `Aura/project.yml` declares
`Aura`, `AuraWidgets`, and `AuraUITests` (a UI-testing bundle) and nothing else. That is the
documented reason the slot's watchdog defect survived to a whole-branch review
(`ShareMapSnapshotter.swift:122-128`).

The API is one wrapping call, not a `begin`/`finish` pair:

```swift
@Observable @MainActor
public final class ShareUpgradePresenter {
    public private(set) var phase: ShareUpgradePhase = .idle

    public init(showDelay: Duration = .milliseconds(300),
                deadline: Duration = .seconds(6),
                minimumDwell: Duration = .seconds(1),
                showDelayTimer: (@Sendable (Duration) async -> Void)? = nil,
                deadlineTimer: (@Sendable (Duration) async -> Void)? = nil,
                dwellTimer: (@Sendable (Duration) async -> Void)? = nil)

    /// Runs one attempt. Arms the hops, awaits `work`, and applies the outcome — including on
    /// cancellation. There is no way to start an attempt without ending it.
    public func attempt(isRetry: Bool, _ work: () async -> ShareUpgradeResult) async

    public func noUpgradePossible()
}

public enum ShareUpgradeResult: Sendable { case gotMap, rejected, stoppedWaiting }
```

`attempt` is the whole answer to "what if `finish` is never called": there is no `finish` to skip.
It applies the terminal phase in a `defer`, so a cancelled or throwing `work` still leaves the
machine in a terminal state rather than an absorbing spinner. It is a no-op if an attempt is
already in flight, so re-entrancy cannot arm two deadline hops that then fight over the phase.

`ShareUpgradeResult` is deliberately image-free so the type stays in AuraKit; the app maps its
`ShareMapOutcome` onto it and keeps the `UIImage`.

**Three separate injected timers**, not one. Revision 1 had a single `sleep` closure serving both
hops, which a test can only tell apart by matching on the `Duration` value (hardcoding production
constants into the test) or by call order. Tests also need the `Gate` half of the
`SharePipelineSlotTests` pattern (`:8-42`) to hold `work` open, not just the timer half —
`Ceiling.firesAtOnce()` is `{ _ in }` and suspends nowhere.

Each timer is `nil`-defaulted with the real closure built **inside** the initializer, in the
defining module. ROH-110: an async closure *default argument* is duplicated into every module
referencing the declaration and the copies can disagree about frame size, which aborts the process
(`SharePipelineSlot.swift:59-67`).

### Where `attempt` sits relative to the 0.8 s sleep

**After the sleep and after its `guard !Task.isCancelled`** (`RideSummaryView.swift:170-172`).
This needs stating because the obvious alternative is fatal: `attempt` at the top of the extracted
function puts the 300 ms hop inside the 0.8 s sleep, so "Adding your map…" appears at t+0.3 s —
mid-entrance on every ride end, as a hard insert. That is verbatim the rev-3 rejection in the
ROH-155 record: "the one drawing operation the rider actually sees during the entrance, and it was
the one left ungated."

So the extracted function is `runUpgrade(glanceDebounce:isRetry:)`, and the sleep is *outside*
`attempt`, not merely parameterised.

### Retry and the exclusive slot — an accepted, named cost

`slot.run` has no cancellation point: both its awaits go through `withCheckedContinuation` and the
pipeline is an unstructured `Task` (`SharePipelineSlot.swift:117`). **Nothing the view does can
retract a committed retry.** A rider who taps Try again, then immediately leaves and opens another
ride, leaves a pipeline running for a ride nobody is looking at, with the next ride queued behind
it — the ROH-155 rev-3 reproduction reached through the button instead of the sleep.

This is not solvable at this layer and this design does not pretend to solve it. What bounds it:

- Retry is reachable only by an explicit tap, from a terminal phase, on the ride-end presentation.
  The count of slot commitments per presentation is bounded by rider taps on a screen they are
  looking at — a different risk class from unattended History glances, which are unbounded.
- The automatic retry is bounded to one and gated on `.freshAttempt` (below), so it can never be
  the self-sustaining trickle that killed ROH-155 rev 1.
- Retry deliberately skips the 0.8 s glance debounce. The debounce exists to stop a *sub-second
  glance* committing the slot; an explicit tap is the case it was never meant to catch. Note this
  argument covers the tap and **not** the automatic retry — which is a second reason the automatic
  path is gated as narrowly as it is.

The honest summary: this design trades a bounded, rider-initiated slot exposure for the ability to
recover a map at all. `ROH-174`-style lifecycle work on the slot would remove the trade; nothing
here depends on that happening.

### Automatic retry on return from background

Two fixes over revision 1, which was broken in both halves.

**The edge.** Trigger on a return from a *real* background, tracked with a `wasBackgrounded` flag
set when `scenePhase == .background`, not on "`.active` from anything else." `AuraApp.swift:266-268`
already carries the warning in this codebase: "a transient `.inactive` — Control Center, a
notification banner, a permission alert — must NOT" be treated as a background cycle. Revision 1
would have spent its one-shot budget on a notification banner.

**The ordering.** Do not evaluate the phase at the scene edge. On resume the parked belts have to
travel five-plus main-actor hops (belt → latch → `loadStyle` returns → `runPipeline` nil → the
slot's unstructured task unwinds → `defer` release → continuation → `slot.run` returns →
`raster` returns → the view resumes) before the phase is terminal, and the `scenePhase` update
wins that race. Revision 1 would have read `slow`, done nothing, and made the pocketed-phone case
— the headline scenario — a no-op.

Instead: the foreground transition **arms** a pending auto-retry, and the arming is consumed when
the phase next becomes `unavailable(.freshAttempt)` — or immediately, if it already is. No race,
no ordering assumption.

Gated on `.freshAttempt` only, never `.mayRejoin` (which would silently re-join a live pipeline)
and never `slow` or `idle`. One per presentation.

### Copy

| Phase | Line |
|---|---|
| `upgradingVisible` | "Adding your map…" (unchanged) |
| `slow` | "Still adding your map…" |
| `unavailable` (both) | **"Add the map"** — a button, and no sentence |
| `upgraded(confirming: true)` | "Map added" (~2 s) |

**The terminal state is an offer, not an apology.** No failure sentence, no destructive colour, no
warning glyph, no "couldn't". Nothing is broken: the card is finished and Share is enabled. The map
is an upgrade that did not land, and the rider is offered another go.

Revision 2 originally said "Couldn't add the map to your card". Two independent sources rejected
that framing, and they are right:

- The product reviewer at the spec gate: this is a celebration screen, the rider never knew a map
  was coming, and telling them one failed manufactures a problem they did not have.
- An earlier, ungated ROH-161 draft on branch `adaws96/roh-161-share-map-upgrade-silent-failure`
  (§D2) reached the same conclusion independently: "Nothing is broken, so nothing apologises… The
  card is finished; the map is an upgrade that did not land."

Leading with the affordance also disposes of an ambiguity no wording fixed: **there is a real map at
the top of this screen** (`StaticRouteMap`, `RideSummaryView.swift:57`), and offline it is itself
rendering degraded tiles. Any sentence about a map failing, on a screen showing a degraded map,
reads as a diagnosis of the route the rider is looking at. A button that says "Add the map" cannot
be misread that way.

The reason is never named. Nine reject categories, and the rider's action is identical for all of
them; "the style source failed to load" is not a sentence for someone standing over a bike. The
reasons keep going to the log, which is where `ShareMapSnapshotter.swift:116-120` says they were
deliberately put.

"Map added" exists so an explicit tap has a visible result — otherwise a successful retry ends in
the indicator vanishing, which is this issue's exact symptom delivered in response to a deliberate
action.

### Layout: the row is reserved

`unavailable` adds a Button, so it is taller than the spinner rows — and the hint today is a bare
conditional insert with no reserved height (`RideSummaryView.swift:107-114`), directly above Done.
The ROH-155 record already names the consequence: it "is a hard insert that shoves the Done button
down."

**Requirement: the slot reserves its height for the whole presentation whenever an upgrade is
possible, so Done never moves** — not when the phase changes, and not when the map lands and the
row empties. Sized to the tallest state at the current Dynamic Type size. Without this, a rider
scrolling to Done (which sits below the fold on most devices, under map + title + hero + elevation
band + stats + Share) reaches for it as the row grows and lands on Try again, starting a pipeline
they never wanted.

### Accessibility

- The announcement is posted by the **view**, not the presenter: AuraKit imports no UIKit and
  cannot post one.
- Announce the transition into `unavailable` only — not `slow`, and **not** a second `unavailable`
  reached by a failed auto-retry, which would interrupt a VoiceOver rider unprompted seconds after
  they unlock the phone.
- The button's label names what it acts on ("Add the map to your share card"), since "Add the map"
  alone has an ambiguous antecedent for anyone navigating by element on a screen that also shows a
  route map.

## Files

| File | Change |
|---|---|
| `AuraCore/Sources/AuraKit/Sharing/SharePipelineSlot.swift` | `run` returns `SlotOutcome<Value>`; no behavior change |
| `AuraCore/Sources/AuraKit/Sharing/ShareUpgradePhase.swift` | new — phase, `Retryability`, `ShareUpgradeResult` |
| `AuraCore/Sources/AuraKit/Sharing/ShareUpgradePresenter.swift` | new — `attempt`, three timer seams, dwell |
| `AuraCore/Tests/AuraKitTests/SharePipelineSlotTests.swift` | mechanical update to the new return type |
| `AuraCore/Tests/AuraKitTests/ShareUpgradePresenterTests.swift` | new |
| `Aura/Sources/Ride/ShareCard/ShareMapRasterProviding.swift` | `ShareMapOutcome`; protocol return type |
| `Aura/Sources/Ride/ShareCard/ShareMapSnapshotter.swift` | map slot outcomes to `ShareMapOutcome` |
| `Aura/Sources/Ride/ShareCard/ShareCardFileStore.swift` | generation doc comment (now per-attempt, not 0/1) |
| `Aura/Sources/Ride/RideSummaryView.swift` | `presentation:` param; extracted `runUpgrade`; phase-driven reserved row; Try again; background-return handler |
| `Aura/Sources/History/HistoryView.swift` | pass `presentation: .history` |
| `Aura/Sources/Ride/RideHUDView.swift`, `NavigateHUDView.swift` | pass `presentation: .rideEnd` |

Each attempt writes generation *n* rather than reusing generation 1, so a successful retry cannot
overwrite a file a still-live share-sheet consumer may read lazily. Files accumulate per attempt
under the presentation's UUID directory, bounded by taps, in `tmp` — `sweepOtherRides` cannot
collect the current ride's, so this is an accepted cost, stated rather than inherited silently.

## Error handling

| Situation | Behavior |
|---|---|
| No route | `idle` — no indicator, no terminal state, no retry |
| Fallback render fails | `idle`, Share disabled — unchanged |
| Pipeline rejects (any of the nine paths) | `unavailable(.freshAttempt)`, Try again, auto-retry eligible |
| Ceiling fires while the summary waits | `unavailable(.mayRejoin)`, Try again, **not** auto-retry eligible |
| Pipeline succeeds after the deadline | `slow → upgraded`, no failure ever claimed |
| Raster arrives, upgrade re-render fails | `unavailable(.freshAttempt)` — fallback kept, Share enabled |
| Retry warm-hits a cache the pipeline filled after we stopped waiting | `upgraded(confirming: true)`, held ≥1 s by the dwell |
| Retry lands while the share sheet is up | held by `applyOrDeferUpgrade`; see §Risks |
| Backgrounded during the window | belts fire on resume → reject → auto-retry consumed on the terminal phase, not the scene edge |
| View dismissed mid-attempt | the view's task is cancelled; `attempt`'s `defer` still applies a terminal phase. **The slot is not freed** — see §Risks |
| History presentation | no terminal state, no retry — today's behavior |

## Testing

**Unit (`AuraKitTests`, hand-driven timers plus a gate holding `work` open):**

- `SlotOutcome` distinguishes waiter ceiling, owner ceiling, and a pipeline returning nil — three
  cases the old signature collapsed. Existing slot tests keep passing unchanged in behavior.
- show-delay: hidden before, visible after; a result before it never shows the indicator at all
- a retry shows its indicator immediately, with no show-delay
- minimum dwell holds `upgradingVisible` and `slow` for 1 s against an immediate terminal result
- the deadline moves `upgradingVisible → slow` only while the attempt is outstanding
- `.rejected → unavailable(.freshAttempt)`, `.stoppedWaiting → unavailable(.mayRejoin)`
- `slow → upgraded` and `slow → unavailable` both reachable
- `attempt` applies a terminal phase even when `work` is cancelled — never an absorbing spinner
- `attempt` while an attempt is in flight is a no-op and arms no second deadline hop
- `noUpgradePossible()` parks in `idle` and no hop fires

**Device pass (real device, per `CLAUDE.md`):**

1. **Measure the real distribution** of upgrade durations and reject timings at ride end, on wifi
   and on cellular. Revision 1 asserted a "10–11 s success envelope" that was the sum of two
   timeout caps with no evidence; this design does not depend on that number, but the 6 s deadline
   should be checked against reality rather than against arithmetic.
2. Airplane mode at ride end → fast `unavailable(.freshAttempt)` + Try again.
3. Re-enable wifi, tap Try again → map lands, "Map added" shows.
4. Tap Try again *while still offline* → indicator held ≥1 s, back to `unavailable`, no flicker.
5. Pocket the phone during the window, unlock later on wifi → map present without interaction.
6. Pull down Control Center during `unavailable`, dismiss it → **auto-retry must not fire.**
7. Reach for Done as the phase changes → Done must not move. Repeat at an accessibility text size.
8. Retry while the share sheet is open → sheet stays up, card swaps on dismissal.
9. VoiceOver: `unavailable` announced once; a failed auto-retry does not announce again.
10. Reduce Motion on → identical deadline behavior.

Items 7 and 8 overlap ROH-140 (the ROH-126 device-verification tail) on the same surface.

## Risks

- **The share-sheet latch has a 2 s appearance bound** (`RideSummaryView.swift:398`): if
  `UIActivityViewController` takes longer than 2 s to present, `shareSheetUp` goes false while a
  sheet is up, and a late upgrade assigns `shareImage` under it — which the 2026-07-31 device pass
  watched dismiss a presented sheet. Today this is nearly unreachable because upgrades resolve at
  ~1.5 s; **retry makes late landings routine and therefore makes this reachable.** Device-pass
  item 8 targets the happy path; the timeout path needs its own look. This may warrant a separate
  issue rather than expanding this one.
- **A committed retry cannot be retracted.** Named and bounded above, not solved.
- **`SharePresentation.isPresenting` is true for any modal** (`:437-444`), so an unrelated system
  alert during a retry pins `shareSheetUp` and holds the upgrade until it is dismissed.
- **Held `@State` copies of `ShareCardContent`/`title` freeze the units** at first render, so a
  retry after a remote units change (`AuraApp.swift:220-228`) re-renders with stale units. Present
  today too, but retry makes it visible.
- **The `saveFailed` + no-checkpoint case** is where the share card is the *only* artifact of the
  ride that will ever exist — History will not have it. The map failure matters more there than
  anywhere else and Done destroys the retry. This design treats `unavailable` identically in all
  cases; whether that state deserves special handling is a real product question, deferred.

## The ROH-126 clause

Revision 1 quoted ROH-126 §Share flow step 5 to fence off Share, eliding the end of the same
sentence: "the residue is accepted rather than blocking Share **or adding retry UI**." That clause
forbids the thing this document builds, and revision 1 cited it while building it — the exact
failure it accused ROH-155 rev 2 of.

The authority for reversing it is later and explicit: the ROH-155 analysis record
(`2026-07-31-share-prefetch-ownership-design.md`, §What should be built instead) lists "Retry and
terminal state on the summary upgrade" as item 2 of what both reviewers ranked above ROH-155, and
ROH-161 was filed from it. ROH-126's clause is superseded on the retry half and stands on the
Share half — and this document keeps the Share half as a non-goal on that basis, not on ROH-126's.

## What revision 1 got wrong

Kept because the failures are properties of this subsystem, not of one draft.

1. **It modelled `raster(for:) == nil` as "the pipeline failed."** The slot was rewritten so that
   is false, and a checked-in test asserts the opposite. Three separate claims fell with it: that
   retry-while-in-flight was unreachable, that double-tap needed no guard, and that retry "very
   often succeeds."
2. **Its auto-retry could not fire in the case it was written for.** It read the phase at the
   scene edge, which the reject loses by five-plus main-actor hops.
3. **It gated on `.active` from anything**, which this codebase already documents as wrong
   (`AuraApp.swift:266`), so a notification banner would have spent the one-shot budget.
4. **It forgot this view is also the History detail sheet.**
5. **It claimed the phase change was "a text swap, not a layout jump."** The terminal phase adds a
   Button, and the row reserves no height.
6. **It justified `slow` with a fabricated "10–11 s success envelope"** — the sum of two timeout
   caps, contradicted by the ~1.5 s on-device measurement already in the source, and the one
   number it never proposed to measure.
7. **It derived a 6–7 s acceptance reject** that cannot happen: if the render belt fires,
   `runPipeline` rejects before acceptance is ever reached.
8. **It left `begin`/`finish` pairing unenforced**, so a missed `finish` meant a permanent
   spinner — this issue's own bug, reintroduced.
9. **It claimed "this design stops the rider waiting"** on the 20 s ceiling. Nothing in it did.
10. **Its single injected `sleep` closure could not support its own test list.**
