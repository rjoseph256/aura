# ROH-161 — the share-map upgrade needs a terminal state and a retry

Date: 2026-08-06. Branch `adaws96/roh-161-share-map-upgrade-fails-silently-one-attempt-no-terminal`.
Issue: https://linear.app/rohun/issue/ROH-161

**Revision 9.** See §Revision history. This document is the single spec for ROH-161; an earlier
independent draft was folded into it and is recorded there.

> **The automatic retry is cut** — a PO decision on 2026-08-29. Revision 8 made the cut and
> justified it with an impossibility claim; the spec gate refuted that claim by running it, so
> revision 9 keeps the decision and replaces the argument. It also drops `.futile`, revision 8's
> one addition, which all three reviewers refuted independently. See §The automatic retry, and why
> it is cut.
>
> Revision 7 was never pushed — commit `39ab494` exists only on its author's machine — so this
> document continues from revision 6 and treats the revision 7 gate's findings, recorded in the
> Linear issue, as input rather than as repository fact.

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

### What is actually lost, and what is not

Share is never blocked by a failed upgrade. The fallback card renders first, `shareImage` is set,
and Share is enabled from the first frame (`RideSummaryView.swift:139-145`). A rider whose upgrade
fails still has a complete, shareable card.

So the loss is not "I cannot share." It is: **I got the polyline card, I was never told a better
one was attempted, and I do not know that trying again on wifi would very likely work.** That
framing drives every decision below, and it is the reason this is not an error-reporting feature —
which in turn is why the terminal state is an offer rather than an apology (§Copy).

*(This section is taken from the superseded draft's §D0, which stated the problem better than
revision 2 did. Provenance in §Revision history.)*

## The finding that shapes this design

**`raster(for:)` returning nil does not mean the pipeline failed.** The slot was deliberately
rewritten so that it doesn't. `SharePipelineSlot.swift:131-145` is explicit — a waiter's ceiling
"unblocks THIS caller and nothing else… it must not clear the slot, **because the pipeline is
still alive**." The owner's ceiling cancels but does not free the slot (`:129-134`), and
cancellation is not honoured past the render anyway (`ShareMapSnapshotter.swift:227-230`).

So one nil carries two different situations, and they call for different responses (the *type* distinguishes three — waiter ceiling, owner ceiling, and a pipeline returning nil — but the first two call for the same response here):

| What happened | Is the pipeline dead? | Is a retry a real second attempt? |
|---|---|---|
| The pipeline ran and produced no acceptable map | yes | **yes** — no negative cache, so it re-runs in full |
| A ceiling fired while this caller waited | **no** | no — it re-joins the live pipeline, or warm-hits if it has since finished |

At ride end the summary is specifically the **waiter**: the HUD prefetch claims the slot at
+0.7 s (`ShareMapRasterProviding.swift:44-56`) and the ROH-155 record says so outright. So the
ceiling case is not a corner — it is the ride-end shape.

**Erratum, revision 5.** Revisions 2–4 cited
`AuraCore/Tests/AuraKitTests/SharePipelineSlotTests.swift:261`,
`testSameKeyRetryDuringUnwindJoinsTheDyingPipeline`, as "the checked-in proof that they are
different." It is not.

> Renamed since, by `bc8e99f`, to `testSameKeyRetryDuringUnwindStartsNoSecondPipeline`
> (`SharePipelineSlotTests.swift:284`) — named for what it actually proves, so the next citation
> has something to check against. The name in this paragraph is kept because the paragraph is a
> record of what was cited. A reviewer instrumented it: the retry trips its **own waiter ceiling** at
`SharePipelineSlot.swift:145` and returns before ever observing the dying pipeline's result. The
test produces one of the two cases and so demonstrates nothing about the distinction, and its name
is misleading about its own mechanism. What it does prove — `log.started == 1`, no second pipeline
for a live key — is real and is why it exists.

The finding above stands on the type's own documented behaviour (`SharePipelineSlot.swift:131-145`,
`:129-134`) rather than on that test. Stated because a citation that survived three revisions and
three reviewers, and was wrong, is worth more as a correction than as a quiet deletion.

**Second erratum: `.finished(nil)` does not always mean "ran and produced nothing."** At
`SharePipelineSlot.swift:130` a same-key waiter returns whatever the *owner's* task produced — and
if the owner's ceiling fired, `task.cancel()` ran and `runPipeline` returns nil via
`cancelledBeforeStarting` (`ShareMapSnapshotter.swift:174-178`). The joiner then reads
`.finished(nil)`. Since this document says the ride-end summary *is* that joiner, the automatic
retry's whole safety gate — `.freshAttempt` means a retry is a real second attempt — has a hole
in exactly the shape it was built to close. Mitigation in §The automatic retry, and why it is cut.

**A design that offers a retry has to know which nil it got.** That is the seam change below, and
everything else in this document follows from it.

## Goals

- A rider who loses the map is told so, instead of watching a spinner vanish.
- A rider who is told so can ask again, and the app only promises a second attempt when it can
  deliver one.
- A rider whose pipeline is merely slow is never told it failed.
- Every timing rule is unit-testable in a target that has tests, and `begin`/`finish` pairing is
  structurally impossible to get wrong.

## Non-goals

- **Changing Share's behavior during the upgrade window.** ROH-126 §Share flow step 5 accepted
  that a rider sharing in the first seconds gets the fallback card. That stays. See §The ROH-126
  clause below — this design does *not* claim ROH-126 settled it.
- **Touching the 0.8 s sleep, the prefetch, or the slot's policy.** The slot's *return type*
  changes (below); none of its behavior does.
- **A negative cache.** Its absence is what makes retry meaningful.
- **The already-shared-file residue.** A rider who shares at 1 s hands generation 0 to Messages, and
  no later upgrade can change a file already handed over. ROH-126 accepted that; this does not
  reopen it.
- **Lowering the 20 s ceiling.** It is correct for its job.
- **Automatic recovery of any kind** — on foreground return or otherwise. Cut in revision 8; see
  §The automatic retry, and why it is cut. Recovery is a rider tap.

## Scope: both presentations — revision 5 reverses revisions 2–4

`RideSummaryView` is also the History detail sheet (`HistoryView.swift:53`). Revisions 2–4 scoped
the terminal state and the retry to ride end only, flagged that as an unratified assumption, and
were **wrong**. It is now ratified the other way: the offer appears in both presentations, and no
`presentation:` parameter is needed.

The argument for excluding History was that every History open re-runs the pipeline (no negative
cache), so a rider "paging through old rides" while offline would collect an offer on every one.
The plan gate checked the surface: `HistoryView.swift:52-54` presents the summary as a
`.sheet(item:)` from a deliberate row tap. **There is no paging.** It is one offer per sheet the
rider chose to open, individually dismissed — the same rate as ride end. The argument also proves
too much: by it, the "Adding your map…" spinner that History keeps is equally unsolicited.

What the exclusion cost is much larger than what it saved, and it broke the feature's own story.
§Problem says the loss is "I do not know that trying again on wifi would very likely work." The
rider who acts on that goes home, opens History, and taps the ride — and under ride-end-only gets
today's vanishing spinner. Ride end is destroyed by the one button a rider must press to leave it
(`AuraApp.swift:124-135` hides the nav bar, the back button and swipe-back, so Done is very nearly the only
exit). Ride-end-only is a recovery path that exists for about thirty seconds, on the screen where
the rider is least likely to be on wifi. ROH-126 designated the History reopen as *the* recovery
path; excluding it inverted that far more than including the offer does.

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

`run` returns `SlotOutcome<Value>`. **No behavior changes** — every existing policy (who cancels,
who frees the slot, what the ceiling does) is untouched. This is additive information, which is
what makes it safe to do to a type this load-bearing.

The mapping, corrected: `run` has **two** literal `return nil` sites, the waiter ceiling and the
owner ceiling, and **both** become `.stoppedWaiting`. The other two returns hand back a `Value?`
that may itself be nil, and both become `.finished(value)`. **No `return nil` site produces
`.finished(nil)`** — that outcome arises when a same-key waiter returns an owner's task result
that was nil, which is the path §The finding's second erratum is about. Revisions 2–4 said "the
three existing `return nil` sites map to `.stoppedWaiting`, `.stoppedWaiting`, and
`.finished(nil)`", which sends a reader looking for `.finished(nil)` in the wrong place —
precisely the confusion that erratum exists to clear up.

Verified at implementation: a reviewer extracted the pre-change implementation and ran a
seven-scenario differential against the new one — return values, the full `onCeiling` sequence,
`isRunning` at every checkpoint, and the work log — and got identical traces on all seven. The
"no behaviour changes" claim was tested rather than asserted — but the harness was never checked
in, so it cannot be re-run. Treat it as a well-provenanced assertion, which is the category the
revision 5 errata exist to warn about.

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
    case unavailable(Retryability)   // the card has no map
    case upgraded(confirming: Bool)  // map applied; `confirming` when the rider asked and waited
}

/// Why an attempt started. Revision 5 splits this out of a single `isRetry` flag, which
/// conflated "the rider asked" with "skip the show-delay". Revision 8 removes `.automatic`
/// along with the mechanism that was its only caller.
public enum AttemptOrigin: Equatable, Sendable {
    case first        // the summary's own first attempt: show-delay applies
    case riderTap     // an explicit tap: indicator immediately, confirmation on success
}

/// What the spec promises about a tap from a terminal phase. The automatic retry was the only
/// thing that ever BRANCHED on this; both cases now render the same live offer.
public enum Retryability: Equatable, Sendable {
    case freshAttempt   // from .rejected — retry re-runs the pipeline
    case mayRejoin      // from .stoppedWaiting — retry warm-hits or re-joins the live pipeline
}
```

| Phase | Entered when | On screen | Try again |
|---|---|---|---|
| `idle` | no route, or the fallback render failed | nothing | no |
| `upgrading` | attempt starts (first attempt only) | nothing | no |
| `upgradingVisible` | `.first` +300 ms; **immediately** for `.riderTap` | spinner + "Adding your map…" | no |
| `unavailable(.mayRejoin)` | **the 6 s deadline elapses with the attempt outstanding**, or `.stoppedWaiting` | "Add map to card" | **yes** |
| `unavailable(.freshAttempt)` | `.rejected` | "Add map to card" | **yes** |
| `upgraded(confirming: true)` | map applied when the rider had asked and an indicator was on screen | "Map added", persists | no |
| `upgraded(confirming: false)` | map applied with no tap behind it, or before any indicator showed | nothing | no |

`idle` is load-bearing, not a placeholder. Two paths reach it and neither may show a failure:
**no route** (`ShareMapRequest.init` returns nil, `RideSummaryView.swift:146`) — a Try again that
can never succeed would be a lie; and **the fallback render failed** (`:145`), where Share is
disabled and the rider's problem is not the map.

`.freshAttempt` and `.mayRejoin` show the same line and offer the same button. They differ only in
what the spec promises about the tap: from `.mayRejoin` it may warm-hit instantly (the pipeline
finished after we stopped waiting — `raster(for:)` probes the disk cache before the slot,
`ShareMapSnapshotter.swift:143-151`) or re-join for up to another ceiling; from `.freshAttempt` it
re-runs the pipeline in full. Both are real routes to a map and both were asked for, so the
rider-facing treatment is identical.

The upgrade re-render failure also lands here, on `.mayRejoin`. Revision 8 routed it to a third
case that showed no button; revision 9 reverses that — see §The automatic retry, and why it is cut.

### The presentation deadline: 6 s, and what it is for

The ceiling is 20 s and nobody waits 20 s standing over their bike. That is the entire
justification, and it needs no measurement to stand up.

**At 6 s the spinner stops and the offer appears, as `unavailable(.mayRejoin)`.** Nothing here
stops the rider *waiting* in the sense of bounding the pipeline — the slot's own doc notes the
wait is not even bounded by one ceiling (`SharePipelineSlot.swift:50-53`: N different-key
pipelines cost a waiter up to N × ceiling). What the deadline does is stop the rider staring at
a spinner with no way to act, which is the complaint this issue is filed on.

`.mayRejoin` is the honest label for that moment and not a euphemism: the pipeline probably is
still running, so a tap re-joins it — or warm-hits a disk cache the pipeline filled after we
stopped waiting, which is a real second outcome and the reason the tap is not theatre
(`raster(for:)` probes the cache before the slot, `ShareMapSnapshotter.swift:143-151`). When the
original attempt later rejects for real, the phase becomes `unavailable(.freshAttempt)`.

6 s is well past the ~1.5 s the upgrade takes on device (`RideSummaryView.swift:375`, and the
ROH-155 record's correction of the same number) and well before the ceiling.

Counted from the start of the attempt and from nothing else — **not** from the entrance animation.
ROH-155 rev 3 died partly on that: the entrance window is 0.70 s, 0.65 s, or **zero** under Reduce
Motion, so any gate expressed against it makes the rider who asked for no animation wait out an
animation that does not exist. No Reduce Motion coupling, by construction.

It is a **fourth** timeout, and deliberately none of the three that already exist, because all
three serve someone other than the rider:

| Bound | Value | Whose job |
|---|---|---|
| Slot ceiling | 20 s (`SharePipelineSlot.swift:101`) | Protect an app-lifetime singleton from a wedged pipeline |
| Style belt | 4 s (`ShareMapSnapshotter.swift:276`) | Bound one SDK style load |
| Render belt | 6 s (`ShareMapSnapshotter.swift:360`) | Bound one SDK render |
| **Presentation deadline** | **6 s, new** | **Stop the rider waiting** |

**The deadline must not cancel `raster(for:)`.** It changes what is on screen and nothing else. The
pipeline's own comments argue this at length (`ShareMapSnapshotter.swift:161-178`): cancellation
only ever stops a stage from *starting* and never discards a finished one, precisely because a late
cancel "would have saved a 90×60 downsample and one draw, and thrown away ten seconds of style load
and SDK render plus the cache write." With no negative cache, the next request would then pay the
whole pipeline again.

### Auto-apply: the deadline stops the spinner, not the work

When the pipeline succeeds after the deadline, the card upgrades itself and the row clears. **No
tap required.** This is existing behavior — the `.task` is still awaiting the provider — and this
design's job is to not break it.

**Erratum, revision 6 — the suspension claim was false, and it was load-bearing.** Revisions 2–5
said "the belts, the ceiling and the deadline all park under suspension and fire together on
resume, so the rider who locks the phone through the whole window returns to either a finished map
card or a terminal offer." Verified against the source, that is wrong, and the two halves run on
different clocks:

| Bound | Mechanism | Advances while the device sleeps? |
|---|---|---|
| Style belt (4 s), render belt (6 s) | `DispatchQueue.main.asyncAfter(deadline: .now() + n)` (`ShareMapSnapshotter.swift:276`, `:360`) | **No** — `DispatchTime` is the uptime clock |
| Slot ceiling (20 s) | `Task.sleep(for:)` (`SharePipelineSlot.swift:106`) | **Yes** — `ContinuousClock` |
| Presentation deadline (6 s, new) | `Task.sleep(for:)` | **Yes** |

`RideInstant.swift:30-35` documents this split deliberately and for this exact case: *"on Darwin
this is `mach_continuous_time`, which keeps advancing while the machine sleeps. A phone in a jersey
pocket with the screen locked is exactly where a suspending clock under-counts."*

So a phone in a pocket is the case where they diverge, not the case where they agree. The ceiling
runs to 20 s and cancels while the belts are frozen mid-stage; the rider resumes to a **cancelled
pipeline and a cold cache**, not a finished card. The deadline has also long since elapsed, so the
phase on resume is `unavailable(.mayRejoin)` — which is precisely the retryability the automatic
retry is forbidden to fire on.

**Consequences for this design, stated rather than patched over:**

1. Auto-apply is **not** the primary mechanism for the pocketed-phone case. It cannot be: there is
   usually nothing left to apply. It remains correct and worth keeping for the *awake* slow case —
   a rider watching the screen past 6 s — which is a real case, just a different one.
2. The pocketed rider's only route back to a map is a fresh request against a cold cache. The
   automatic retry's `.freshAttempt` gate blocks it, because a ceiling produces `.mayRejoin`.
   **This is now the open hole in the design**, and it is the headline scenario. A disk-cache
   re-probe on foreground does not close it either — the cache is cold, because the pipeline was
   cancelled before it wrote anything.

   > **Closed by removing the mechanism rather than repairing it.** A fresh request against a cold
   > cache is what the offer's button already issues, and it is not gated on `Retryability` at all.
   > The hole was only ever a hole in the *automatic* path. See §The automatic retry, and why it is
   > cut.
   >
   > **And the "cold cache" above is over-stated.** Cancellation past the render is a deliberate
   > no-op (`ShareMapSnapshotter.swift:227-230`), which this document relies on two sections
   > earlier to argue the deadline must not cancel. A suspension that lands in the tail therefore
   > completes on resume, writes the cache, and returns an image. So the pocketed rider's outcome
   > is **nondeterministic** — a finished card or a live offer, depending on which stage the freeze
   > caught — and device-pass item 5 must record which of the two it saw across repeats rather than
   > assert one as expected. The other ROH-161 branch's spec says exactly this and the code sides
   > with it.
3. ROH-126's note that "suspension parks both belts and the ceiling together so they fire on the
   same resume" inherits the same error. That claim was the decisive argument for reversing
   erratum (a) in `2026-07-30-roh126-slot-watchdog-cancellation.md`. The *conclusion* there
   survives on other grounds, but the reason given for it does not, and the note should be
   corrected rather than left to be cited again.

Nothing below has been rewritten to account for this yet. It is recorded here first because it was
found during implementation, it invalidates a paragraph three gates read without catching, and
guessing at the fix in the same edit that discovers the problem is how the earlier revisions of
this document went wrong.

The swap goes through the existing `applyOrDeferUpgrade` (`RideSummaryView.swift:376`), which
already holds an upgrade back rather than swapping it out from under a presented share sheet. Retry
promotes that path from rare to routine, which is why verifying it is mandatory rather than
optional — see §Risks on the latch's 2 s appearance bound.

### `slow` is deleted — revision 5 reverses revision 2 here

Revisions 2–4 had a fourth phase, `slow`, entered at the deadline: the spinner stayed and its
wording changed to "Still adding your map…", with the button withheld until the app *knew* the
wait was over. The superseded draft's §D5 had argued for one offer state either way, and revision
2 rejected it because "at the deadline the pipeline is usually still running, and a tap then
commits a second waiter to it… an affordance which feels like an action and is not one."

**That argument does not survive the plan gate, and the draft was closer to right.** Three
findings, none of which revision 2 had:

- **The copy contradicted itself.** The app said twice over six seconds that it was adding the
  map, then offered a button asking the rider to add the map, with no sentence marking that the
  earlier statement had stopped being true.
- **"Still" concedes lateness while offering no recourse**, which converts a wait the rider was
  ignoring into one the app has flagged as abnormal — and so maximises this document's own
  top-ranked risk, that the offer makes riders wait to share who otherwise would not have.
- **The minimum dwell made it briefly dishonest.** A reject at 6.1 s held "Still adding your
  map…" until 7.1 s, a full second after the app knew.

The "affordance that isn't an action" objection was also overstated: a tap at the deadline probes
the disk cache first, so on the case that matters — the pipeline finished moments after we
stopped waiting — it returns a map immediately. `.mayRejoin` names exactly that.

**What the deletion costs, stated plainly.** The rider can now be shown an offer while a healthy
pipeline is seconds from landing, and tapping it buys them nothing beyond what auto-apply would
have delivered. That is the same cost the 6 s number always carried; it is now visible as a
button rather than hidden in a spinner's wording.

### One rider-visible attempt, not one attempt

Deleting `slow` means the button is live while an attempt is outstanding, which the
one-attempt-at-a-time rule of revisions 2–4 would have rendered a **dead button** — the guard
would swallow the tap silently. So the rule is restated in the only form that survives:

> **A map from any attempt is applied. Only the newest attempt's terminal outcome may set the
> phase.**

Attempts carry a monotonic generation. An older attempt resolving `.rejected` or
`.stoppedWaiting` is discarded; an older attempt resolving with a *map* is still applied, because
a map is a map. Two concurrent `raster(for:)` callers are exactly what `SharePipelineSlot` is
built for — it guarantees at most one pipeline regardless — so this costs a second waiter and no
second render.

The generation is load-bearing for a second reason the architecture review reproduced: without
it, a dwell hop armed under attempt *n* re-applies attempt *n*'s terminal phase over attempt
*n+1*'s live indicator. Every hop must check its generation, not merely its cancellation.

### Minimum dwell, so nothing flashes

A reject can land at essentially any time up to ~10 s: the style belt caps at 4 s (`:276`) and the
render belt at 6 s (`:360`), and they are caps, not durations — if the render belt fires,
`renderMapRasterWithChrome` returns nil at `:373` and `runPipeline` rejects at `:222-226` without
ever reaching acceptance. So there is no deadline value that cleanly separates rejects from the
deadline; some rejects will always land just after it.

Rather than tune a constant against that, the presenter enforces a **minimum visible duration of
1 s on any indicator it shows**. `upgradingVisible` stays put for at least 1 s before any
transition out of it is applied. This is a rule in a tested type, not a number to re-tune per
device.

With `slow` deleted there is exactly one indicator phase and therefore exactly one dwell, which
removes the dwell-restart the architecture review found unmanaged.

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
    public func attempt(origin: AttemptOrigin, _ work: () async -> ShareUpgradeResult) async

    public func noUpgradePossible()
}

public enum ShareUpgradeResult: Sendable { case gotMap, rejected, stoppedWaiting }
```

`attempt` is the whole answer to "what if `finish` is never called": there is no `finish` to skip.

**Two sentences stood here through revisions 2–8 and were false in the committed code.** Removed in
revision 9 rather than reworded, because §Testing asked for a test of each and an implementer
working from the list would have written both.

* *"It applies the terminal phase in a `defer`."* There is no `defer`; the phase is applied inline
  after `await work()`. Revision 5's erratum 7 already retracted the behavioural claim and §Error
  handling contradicts it in bold, but this paragraph and §Testing were never updated. `work` is
  also non-throwing, so "a throwing `work`" was never expressible.
* *"It is a no-op if an attempt is already in flight."* It is not, and it must not be. §One
  rider-visible attempt abolishes that rule on purpose: the offer is live *while* an attempt is
  outstanding — which at the deadline is the normal ride-end shape — so a guard here would swallow
  the most likely tap in the feature and produce the dead button this issue exists to remove. The
  real rule is the generation: a new attempt supersedes, and hops are cancelled.

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
(`SharePipelineSlot.swift:90-93`).

### Where `attempt` sits relative to the 0.8 s sleep

**After the sleep and after its `guard !Task.isCancelled`** (`RideSummaryView.swift:170-172`).
This needs stating because the obvious alternative is fatal: `attempt` at the top of the extracted
function puts the 300 ms hop inside the 0.8 s sleep, so "Adding your map…" appears at t+0.3 s —
mid-entrance on every ride end, as a hard insert. That is verbatim the rev-3 rejection in the
ROH-155 record: "the one drawing operation the rider actually sees during the entrance, and it was
the one left ungated."

So the extracted function is `runUpgrade(glanceDebounce:origin:)`, and the sleep is *outside*
`attempt`, not merely parameterised.

### Retry and the exclusive slot — an accepted, named cost

`slot.run` has no cancellation point: both its awaits go through `withCheckedContinuation` and the
pipeline is an unstructured `Task` (`SharePipelineSlot.swift:151`). **Nothing the view does can
retract a committed retry.** A rider who taps Try again, then immediately leaves and opens another
ride, leaves a pipeline running for a ride nobody is looking at, with the next ride queued behind
it — the ROH-155 rev-3 reproduction reached through the button instead of the sleep.

This is not solvable at this layer and this design does not pretend to solve it. What bounds it:

- Retry is reachable only by an explicit tap, from a terminal phase, on the ride-end presentation.
  The count of slot commitments per presentation is bounded by rider taps on a screen they are
  looking at — a different risk class from unattended History glances, which are unbounded.
- Every slot commitment past the first is a deliberate tap. Revision 8's cut of the automatic
  retry tightens this bound rather than loosening it: no path now commits the slot without the
  rider, so the self-sustaining trickle that killed ROH-155 rev 1 has no mechanism here at all.
- Retry deliberately skips the 0.8 s glance debounce. The debounce exists to stop a *sub-second
  glance* committing the slot; an explicit tap is the case it was never meant to catch.

The honest summary: this design trades a bounded, rider-initiated slot exposure for the ability to
recover a map at all. `ROH-174`-style lifecycle work on the slot would remove the trade; nothing
here depends on that happening.

### The automatic retry, and why it is cut

**Removed.** No `wasBackgrounded` flag, no arming, no consumption, no one-shot budget, no
`scenePhase` handler in `RideSummaryView`. Recovery from a terminal phase is a rider tap.

A PO decision taken on 2026-08-29, recorded at length rather than deleted quietly, because the
mechanism was load-bearing in four revisions.

**It failed three times, each with a different proximate cause.**

| Revision | The mechanism | How it failed |
|---|---|---|
| 1 | Read the phase at the `scenePhase` edge | The reject loses that race by five-plus main-actor hops, so it read `slow` and did nothing. The headline scenario was a no-op. |
| 2–5 | Arm at the edge, consume when the phase becomes `unavailable(.freshAttempt)` | Erratum, revision 6: a pocketed phone's ceiling fires while the belts are frozen, so the phase on resume is `.mayRejoin` — the one value the gate forbids. Recorded there as "the open hole in the design". |
| 7 (unpushed) | One-time reclassification of `.mayRejoin` → `.freshAttempt` on the scene edge | Three reviewers, all REVISE. One implemented it and ran the headline scenario: `FINAL_PHASE=unavailable(mayRejoin) AUTO_RETRIES=0`. It also read the phase at the scene edge, which revisions 2–5 had forbidden in bold as the defect that killed revision 1. |

#### Revision 8 claimed this was impossible. It is not, and the gate proved it by running it

Revision 8 argued that the app cannot know, at a scene edge, whether an in-flight attempt will
produce a map, because `SharePipelineSlot` is deliberately built so that it cannot — and concluded
the information was unrecoverable. **That argument is withdrawn.**

A spec reviewer changed one predicate — the consume gate from `.freshAttempt` to any terminal
`unavailable` — and replayed the headline scenario against the committed presenter:

```
testPocketedPhoneCeilingThenForegroundFiresOneAutomaticRetry — passed
  phase == .unavailable(.mayRejoin), AUTO_RETRIES == 1
```

Two things follow. The arm/consume design **already** does not read the phase at the scene edge —
that is what arming is for — so revision 7's failure is evidence that *reclassification on the
scene edge* fails, not that the mechanism cannot work. And `SharePipelineSlot.isRunning` is public
and documented as *"observable rather than inferred"*, so the sentence "built so that it cannot
know" was wrong about the type. It is not reachable from the view — `ShareMapSnapshotter.slot` is
`private` and the seam exposes only `raster(for:)` — so using it would need a seam change, but that
is a cost, not an impossibility.

Generalising three failed mechanisms into an impossibility was the weakest step in revision 8, and
handing the PO a proof where the honest answer was a judgement call was the wrong way to get a
decision.

#### The actual reason, which is a cost and survives scrutiny

Firing on `.mayRejoin` means the app commits a second waiter to a pipeline that may still be
alive, on the rider's behalf, without being asked. That is precisely what `.mayRejoin` was
introduced to forbid. The one-line version buys back the rider's tap by doing the thing the design
spent four revisions deciding not to do — and it would need its own device pass to establish that
the unasked re-join is harmless.

**Against that, the rider loses exactly one tap.** §Phases gives both `unavailable` cases the same
live "Add map to card" button, so the pocketed rider — the headline scenario, and the case the
revision 6 erratum said was uncovered — returns to a button that works. The automatic retry was
never the difference between recovery and no recovery; it was the difference between recovery and
recovery-without-asking. For a defect whose user-visible payload is a button, that is not worth a
mechanism with this failure record.

The goal revisions 2–8 carried — *"the automatic recovery fires on a signal that actually
correlates with the failure's cause"* — is dropped rather than failed a fourth time.

#### Revision 8's `.futile` is also gone

Revision 8 added a third `Retryability` case for the upgrade re-render failure, showing no button,
reasoning that a retry warm-hits the cached raster and re-fails *deterministically*. All three
reviewers refuted it independently, and they were right on both halves:

* **It was unreachable.** No `ShareUpgradeResult` case maps to it, `phase` is `private(set)`, and
  §Files listed no new result case. It was a state nothing could enter.
* **The determinism premise is false.** `RideCardRenderer.make` returns nil on `ImageRenderer`
  producing no image, on `pngData()`, or on the write throwing — memory and disk pressure, none of
  them a function of the raster. And the *same renderer* succeeded on the fallback card seconds
  earlier, or we would be in `idle` with Share disabled; the only deltas on the second call are an
  extra 1080×1350 raster in memory and a different write URL. Transient pressure is therefore the
  leading explanation, and ride end — HealthKit write, Live Activity, widget reload — is exactly
  when it bites.

Revision 8 also priced the alternative wrongly, calling it "a new parameter through
`ShareMapRasterProviding`". The failure is not in the raster pipeline; the raster is fine and
cached. The alternative is **doing nothing**: leave the case on `.mayRejoin`, and the existing
offer warm-hits the cached raster and re-runs the renderer for free. So `.futile` would have added
code in order to guarantee a rider no recovery on a path where the free option gives them a real
chance of one — and it did so by designing in the silent failure this issue was filed to remove,
which §Goals forbids in its first line.

#### What comes out of the code

All of this was committed and tested, so the deletion is real work:

| Symbol | File | Disposition |
|---|---|---|
| `AttemptOrigin.automatic` | `ShareUpgradePhase.swift` | deleted |
| `onAutomaticRetry` | `ShareUpgradePresenter.swift` | deleted |
| `armedAutomaticRetry`, `hasAutomaticallyRetried` | `ShareUpgradePresenter.swift` | deleted |
| `armAutomaticRetry()`, `consumeAutomaticRetryIfDue()` and its call site | `ShareUpgradePresenter.swift` | deleted |
| `isAttempting` | `ShareUpgradePresenter.swift` | deleted — its only consumer was a deleted test |
| `terminal(for:origin:)` | `ShareUpgradePresenter.swift` | loses the parameter entirely: `origin` is no longer read there, and `confirming` is just `indicatorShown` |
| the four automatic-retry tests | `ShareUpgradePresenterTests.swift` | deleted with their subject |
| doc comments asserting the automatic retry | `ShareUpgradePhase.swift` | rewritten — `Retryability`, `AttemptOrigin` and `upgraded(confirming:)` each justified themselves by citing the deleted case |

`AttemptOrigin` keeps two cases. It is read in exactly one place (whether the show-delay applies),
and it could collapse to the boolean revision 5 replaced it with — but a named case at the call
site says more than `isRetry: false`, and churn here buys nothing.

Plan Task 8 loses its background-return half. Its accessibility half **also changes**, contrary to
revision 8's claim that it survives: the announcement rule is rewritten above and the plan's step
names `AttemptOrigin.automatic` as its mechanism. Task 6 Step 2's render-failure routing is
unchanged after all, since `.futile` is gone. Tasks 1–2 survive apart from the deletions above and
the ROH-186 fix below.

#### ROH-186 is fixed here, not deferred

The gate reproduced it: the minimum dwell did not exist in production. `cancelHops()` runs one line
before `attempt` awaits the dwell gate, and the production timer is a cancellable `Task.sleep`
whose cancellation `try?` swallows — so the hop fell through to `gate.open()` immediately and a
1000 ms floor measured **10.8 ms**. Every test missed it because `ManualTimer` ignores cancellation,
so they asserted the double's semantics on the one axis that mattered.

It is fixed on this branch rather than left to ROH-186, because the cut makes the rider tap the
only recovery path and the dwell is what makes a tap that warm-hits in milliseconds visible at all.
The dwell hop now lives outside `cancelHops()`' reach. Guarding it on `Task.isCancelled` instead
would wedge: the gate would never open, `attempt` would never return, and the phase would stick on
an absorbing `.upgradingVisible`.

**One related gap is recorded, not fixed.** §Minimum dwell says the floor applies to *any*
transition out of `upgradingVisible`, but the deadline hop writes `.unavailable(.mayRejoin)`
without consulting the gate. That is currently harmless only because 300 ms and 6 s are far apart —
and device-pass open question 1 is chartered to change exactly that spacing. If the deadline drops
below roughly 1.3 s, this needs building.

### Copy

| Phase | Line |
|---|---|
| `upgradingVisible` | "Adding your map…" (unchanged) |
| `unavailable` (both) | **"Add map to card"** — a button, and no sentence |
| `upgraded(confirming: true)` | "Map added" — persists, does not self-clear |

**The button names its destination.** Revisions 2–4 said "Add the map", and §Accessibility then
required the VoiceOver label to be "Add the map to your share card" because "'Add the map' alone
has an ambiguous antecedent on a screen that also shows a route map." If the antecedent is
ambiguous for a VoiceOver rider it is ambiguous for a sighted one; the design had fixed it for one
population and left the other with the version it had just diagnosed as broken. The share card is
never rendered on this screen — it exists only as a PNG behind `ShareLink` — so the visible label
has to say which artifact it acts on.

**"Map added" does not self-clear.** Revisions 2–4 gave it ~2 s. A rider who taps a button they
know takes seconds looks away — at the bike, at traffic, at a friend — and two seconds later
looks back at an empty row indistinguishable from "I imagined tapping it", with the button gone
and no recovery gesture. The row's height is reserved for the whole presentation anyway, so
persisting costs no layout.

It is also shown in one case revisions 2–4 missed. `confirming` was `isRetry`, so a **first**
attempt that showed a spinner and then succeeded at 8 s emptied the row silently — a spinner
vanishing with nothing else on screen changing, which is §Problem's sentence verbatim. It is now
simply `an indicator was visible` — revision 8 removed the `origin != .automatic` clause together
with the origin it tested. Every attempt now has a rider behind it, the first implicitly and a
retry explicitly, so there is no longer an attempt whose success has to stay silent.

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
reads as a diagnosis of the route the rider is looking at. Revisions 2–4 concluded from this that
"a button that says 'Add the map' cannot be misread that way", which was asserted rather than
argued and was contradicted four paragraphs later by §Accessibility's own reason for lengthening
the VoiceOver label. Revision 5 names the destination in the visible label too — see §Copy.

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
row empties. Without this, a rider scrolling to Done reaches for it as the row grows and lands on
the offer button, starting a pipeline they never wanted. Done sits below the fold on most devices
(under map + title + hero + elevation band + stats + Share) and is the **only** exit:
`AuraApp.swift:124-135` hides the nav bar, the back button and swipe-back, so every rider must
scroll to it on every ride.

Two things revision 5 pins that revisions 2–4 left open, both found at the plan gate:

**"Whenever an upgrade is possible" is not derivable from `.idle`.** `.idle` is both "no upgrade
possible" (no route, failed fallback) and "none attempted yet" — and at ride end the presenter
sits in `.idle` for the first ~0.8 s, because the debounce is outside `attempt`. Reserving on
`.idle` puts dead space on a no-route ride; not reserving until `attempt` starts pops the row in
at t≈0.8 s, a hard insert mid-entrance, which is the exact failure this requirement exists to
prevent and the one ROH-155 rev 3 died on. **The source of truth is `request != nil`** — the view
knows whether a `ShareMapRequest` could be built before any phase exists.

**"Sized to the tallest state" is a mechanism, not a preference.** Written as a fixed height it
breaks at exactly the sizes that matter: at AX3 and above the button label wraps to two lines, the
row exceeds its reservation, and Done moves — for the rider least able to recover from it. Build
it as a `ZStack` rendering every phase's content with only the active one visible and the rest
`.accessibilityHidden(true)`. That sizes to the maximum at any Dynamic Type size by construction
and cannot drift.

**The cost, named rather than inherited.** This is roughly a 44 pt row plus `Spacing.xl` of
permanent space between Share and Done on *every* ride, including the ~95 % where the map lands in
1.5 s and the row is empty throughout. Accepted: a rider who taps the wrong control on a
celebration screen is worse than a gap. Device pass item 7 is where it gets judged.

### Accessibility

- The announcement is posted by the **view**, not the presenter: AuraKit imports no UIKit and
  cannot post one.
- Announce on entry to `unavailable` **from a non-`unavailable` phase**, and on any `unavailable`
  reached from a rider tap. Not on a `Retryability` change within `unavailable`.
  
  Revision 8 said "announce every transition into `unavailable`" and that was wrong in a case it
  did not consider: a single first attempt with no taps at all can hit the deadline at 6 s
  (`.mayRejoin`) and then reject at ~10 s (`.freshAttempt`), which §Testing lists as reachable.
  Both render the identical row, so "every" interrupts a VoiceOver rider twice to say one thing,
  with nobody having asked. The rationale offered for widening it — "every retry is a tap now" —
  does not cover that sequence, because it is not a retry.
- The announcement string must state an **outcome**, and a failed tap must not sound like a
  successful one. Revision 8 widened the rule without specifying the copy, which would have left a
  VoiceOver rider unable to tell "Map added" from "still no map".
- The button's accessibility label names what it acts on ("Add the map to your share card"). Its
  *visible* label now does too ("Add map to card") — see §Copy.
- The row's identity changes from a `Text` to a `Button` at the terminal phase, which drops
  VoiceOver focus sitting on it. Device pass item.

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
| `Aura/Sources/Ride/RideSummaryView.swift` | extracted `runUpgrade`; phase-driven reserved row; the offer button; `applyOrDeferUpgrade` re-checks `isPresenting`. **No `scenePhase` handler** — revision 8 |

No call site changes: revision 5 drops the `presentation:` parameter along with the ride-end-only
scope, so `AuraApp.swift:131` and `HistoryView.swift:53` are untouched. (Revisions 2–4's Files
table named `RideHUDView.swift` and `NavigateHUDView.swift` as the ride-end call site. Neither
constructs a `RideSummaryView` — those two files own the ride-end *prefetch*, per ROH-126 §Share
flow step 1. The only two call sites are the ones above.)

Each attempt writes generation *n* rather than reusing generation 1, so a successful retry cannot
overwrite a file a still-live share-sheet consumer may read lazily. Files accumulate per attempt
under the presentation's UUID directory, bounded by taps, in `tmp` — `sweepOtherRides` cannot
collect the current ride's, so this is an accepted cost, stated rather than inherited silently.

## Error handling

| Situation | Behavior |
|---|---|
| No route | `idle` — no indicator, no terminal state, no retry |
| Fallback render fails | `idle`, Share disabled — unchanged |
| Pipeline rejects (any of the nine paths) | `unavailable(.freshAttempt)`, offer shown |
| Ceiling fires while the summary waits | `unavailable(.mayRejoin)`, offer shown |
| Pipeline succeeds after the deadline | `unavailable(.mayRejoin) → upgraded`, no failure ever claimed |
| Raster arrives, upgrade re-render fails | `unavailable(.mayRejoin)` — fallback kept, Share enabled, offer shown. Revision 8 routed this to a no-offer state on the grounds that a retry re-fails deterministically; revision 9 reverses that, because `RideCardRenderer.make` fails on `ImageRenderer` returning nil, a PNG encode, or a write, none of which is a function of the raster — and the same renderer succeeded on the fallback seconds earlier, so transient memory or disk pressure is the leading explanation and a retry has a real chance |
| Retry warm-hits a cache the pipeline filled after we stopped waiting | `upgraded(confirming: true)`, held ≥1 s by the dwell |
| Retry lands while the share sheet is up | held by `applyOrDeferUpgrade`; see §Risks |
| Backgrounded during the window | belts fire on resume → the phase settles terminal → the offer is on screen and live. No automatic action (revision 8) |
| View dismissed mid-attempt | **`attempt` does not return and no terminal phase is applied.** `slot.run` has no cancellation point (`SharePipelineSlot.swift:176-177` — both awaits are `withCheckedContinuation` or a non-throwing `Task.value`), so cancelling the view's task never makes `work()` return. Harmless, because the view is gone; but revisions 2–4 claimed the opposite, and a test written against a cancellable stub would have asserted the stub rather than the system. **The slot is not freed** — see §Risks |
| History presentation | identical to ride end (revision 5 — see §Scope) |

## Testing

**Unit (`AuraKitTests`, hand-driven timers plus a gate holding `work` open):**

- `SlotOutcome` distinguishes waiter ceiling, owner ceiling, and a pipeline returning nil — three
  cases the old signature collapsed. Existing slot tests keep passing unchanged in behavior.
- show-delay: hidden before, visible after; a result before it never shows the indicator at all
- a retry shows its indicator immediately, with no show-delay
- minimum dwell holds `upgradingVisible` for 1 s against an immediate terminal result
- the deadline moves `upgrading`/`upgradingVisible → unavailable(.mayRejoin)` only while the
  attempt is outstanding, and is inert once it has resolved
- `.rejected → unavailable(.freshAttempt)`, `.stoppedWaiting → unavailable(.mayRejoin)`
- `unavailable(.mayRejoin) → upgraded` (the deadline fired, then the pipeline landed) and
  `unavailable(.mayRejoin) → unavailable(.freshAttempt)` (then it rejected) both reachable
- an older attempt's `.rejected` never overwrites a newer attempt's live indicator; an older
  attempt's **map** is still applied
- a second `attempt` while one is in flight supersedes it by generation, and the older attempt's
  reject never overwrites the newer attempt's live indicator. **Fire the newer attempt's dwell
  before resolving the older one**, or the older attempt parks on that gate and returns without
  ever reaching the guard — a mutation run with both generation guards deleted passed 16/16
- the minimum dwell holds against a timer that HONOURS cancellation, not only against the fake.
  `cancelHops()` runs one line before `attempt` awaits the dwell gate, so a cancellable production
  timer used to open it instantly (ROH-186)
- `noUpgradePossible()` parks in `idle` and no hop fires

**Device pass (real device, per `CLAUDE.md`):**

1. **Measure the real distribution** of upgrade durations and reject timings at ride end, on wifi
   and on cellular. Revision 1 asserted a "10–11 s success envelope" that was the sum of two
   timeout caps with no evidence; this design does not depend on that number, but the 6 s deadline
   should be checked against reality rather than against arithmetic.
2. Airplane mode at ride end → fast `unavailable(.freshAttempt)` + Try again.
3. Re-enable wifi, tap Try again → map lands, "Map added" shows.
4. Tap Try again *while still offline* → indicator held ≥1 s, back to `unavailable`, no flicker.
5. **The headline scenario.** Pocket the phone through the whole window, unlock later on wifi.
   Per the revision 6 erratum the expected state is `unavailable(.mayRejoin)` with a live offer,
   *not* a finished card — confirm which one actually appears, since that erratum was reasoned
   from source and has never been watched happen. Then tap the offer and confirm the map lands.
6. Confirm nothing retries on its own: return from background during `unavailable` and watch that
   the phase and the row do not move until tapped.
7. Reach for Done as the phase changes → Done must not move. Repeat at an accessibility text size.
8. Retry while the share sheet is open → sheet stays up, card swaps on dismissal.
9. VoiceOver: entering `unavailable` announces once; the deadline-then-reject sequence on a single
   attempt announces **once**, not twice; a failed rider-initiated retry does announce, and is
   distinguishable from the success announcement.
10. Reduce Motion on → identical deadline behavior.

Items 7 and 8 overlap ROH-140 (the ROH-126 device-verification tail) on the same surface.

**Open questions the device pass has to answer, not confirm.** These are the ones where the design
is genuinely guessing, and they are phrased as questions on purpose — device-pass item 10 of
revision 1 asked a tester to confirm that 6 s equals 6 s, which cannot fail and detects nothing.

1. Is 6 s right, or does the terminal offer appear too eagerly ahead of a pipeline that was about
   to land?
2. Does the auto-applied swap read as delightful or as a glitch when the rider is looking at it?
3. **Does the offer change sharing behaviour** — do riders wait for a map they would not otherwise
   have waited for? (See §Risks.)

## Risks

- **The share-sheet latch's 2 s appearance bound is now fixed here, not deferred** (revision 5).
  `RideSummaryView.swift:398` polls for the sheet 20 × 100 ms and gives up; if
  `UIActivityViewController` takes longer — a cold first share builds its extension list, and over
  2 s is not exotic — `shareSheetUp` goes false while a sheet is up, and a late upgrade assigns
  `shareImage` under it, which the 2026-07-31 device pass watched dismiss a presented sheet.
  Revisions 2–4 recorded this as a deferred risk while also stating that "retry makes late
  landings routine and therefore makes this reachable" — which is an argument for fixing it, used
  as an argument for deferring. The fix is structural and two lines: `applyOrDeferUpgrade`
  re-checks `SharePresentation.isPresenting` at assignment time instead of trusting the latch
  alone.
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
- **The offer may make riders wait to share who otherwise would not have.** An affordance implies
  something better is coming. A rider who would have shared the polyline card at 3 s might now sit
  and wait for a map that may never arrive — so the feature's cost is paid by riders it does not
  help. This is a real behaviour change, it cannot be tested off-device, and it is the one risk here
  that argues for the *absence* of the feature. Device-pass open question 3.
  *(From the superseded draft's §Risks; neither revision 2 nor any of the three gate reviewers
  raised it.)*
- **Auto-apply changes a card under a rider who has already decided.** `applyOrDeferUpgrade` covers
  the presented-sheet case. It does not cover a rider who is simply looking at the card when it
  swaps. Accepted; device-pass open question 2.

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

## Revision history

**Revision 1** (`d081e03`). Two terminal states driven by a presentation deadline. Went to the
three-reviewer adversarial gate and did not survive it; §What revision 1 got wrong is the record,
kept because the failures are properties of this subsystem rather than of one draft.

**Revision 2** (`2e89441`). Rebuilt around outcome-typed results after the gate's central finding:
`raster(for:)` returning nil does not mean the pipeline failed. Scoped to ride-end, fixed the
auto-retry's edge and its ordering race, replaced a fabricated success envelope with a
minimum-dwell rule, made `begin`/`finish` structurally unskippable.

**Revision 3** (`de798ef`). Terminal state became an offer rather than an apology.

**Revision 4.** Folded in an earlier, independent ROH-161 draft — dated 2026-08-05, commit
`7622501`, written on the local-only branch `adaws96/roh-161-share-map-upgrade-silent-failure` and
never gated or pushed. It was found after revision 3 and it is the reason this section exists.

It had reached several conclusions this line of work had not, and each is now incorporated with a
pointer to it at the point of use:

- **§D0**, the statement of what is actually lost — better than revision 2's, and now §Problem's
  "What is actually lost, and what is not".
- **§D2**, the offer-not-apology framing, reached independently of the gate's product reviewer.
  Adopted in revision 3 and credited in §Copy.
- **§D3**, the four-timeouts table and the rule that the deadline must not cancel `raster(for:)`.
- **§D4**, auto-apply as the *primary* mechanism for the pocketed-phone case, which this line of
  work had wrongly assigned to the auto-retry.
- **§Risks**, that the offer may make riders wait to share who otherwise would not have — the one
  risk here that argues against building the feature at all, and which neither revision 2 nor any
  of the three gate reviewers raised.
- **§D5**, that the deadline and a reject should present identically. This one is **rejected**, and
  §The alternative considered says why: the outcome types make a distinction available that the
  draft could not see.

The draft's own §D7 claimed a retry "cannot stack pipelines… two rapid taps produce two awaiting
callers of one pipeline, which is harmless." That is true of the same-key join and misses the
ceiling case, which is the same error revision 1 made from the other direction — two independent
drafts reaching it is the strongest evidence that `nil` from this provider is genuinely misleading,
and the best argument for the seam change in §The seam.

**Revision 5.** Written after the *plan* gate — three reviewers against
`docs/superpowers/plans/2026-08-09-roh161-share-upgrade-terminal-state.md`, two of whom built
reproduction packages and ran the plan's own tests rather than reasoning about them. The plan's
defects are recorded in the plan; these are the ones that turned out to be this document's:

Three product decisions, all ratified with the PO:

1. **`slow` is deleted** and the deadline now produces `unavailable(.mayRejoin)`. Revision 2's
   rejection of the superseded draft's §D5 does not survive: the copy contradicted itself, "Still"
   conceded lateness while offering no recourse, and the dwell made the state briefly dishonest.
   §D5 was closer to right than revision 2 was, and §D7's "two awaiting callers of one pipeline,
   which is harmless" is now adopted as the *one rider-visible attempt* rule — the third finding
   from that draft to outlive the revision that dismissed it.
2. **The ride-end-only scope is reversed.** The exclusion rested on riders "paging through" old
   rides; `HistoryView.swift:52-54` presents a `.sheet(item:)` from a deliberate row tap and there
   is no paging. The `presentation:` parameter goes with it.
3. **The share-sheet 2 s bound is fixed here** rather than deferred, since this document already
   argued that retry is what makes it reachable.

Four errata against revisions 2–4, none of which three spec reviewers caught:

4. **The `testSameKeyRetryDuringUnwindJoinsTheDyingPipeline` citation was wrong** — it trips its
   own waiter ceiling and never observes the dying pipeline's result. §The finding.
5. **`.finished(nil)` does not always mean the pipeline exhausted itself** — a same-key joiner can
   read an owner-cancelled nil. Narrower than it looks; §The automatic retry, and why it is cut.
6. **A render failure was mapped to `.freshAttempt`**, making the one-shot automatic retry
   eligible on a path that re-fails deterministically against a now-warm cache. §Error handling.
7. **"`attempt` applies a terminal phase even when `work` is cancelled" is false** — `slot.run`
   has no cancellation point, so `work()` never returns and `attempt` never returns. The test
   revisions 2–4 specified for it would have asserted a stub. §Error handling.

And two carried from the plan gate into the design because the view cannot be unit-tested here:
`confirming` was `isRetry`, which silently dropped the confirmation for a slow *first* attempt —
this issue's own symptom, in response to nothing — and `isRetry` conflated "the rider asked" with
"skip the show-delay", so the automatic retry would have announced itself to a rider who had just
unlocked their phone. Both are fixed by `AttemptOrigin`.

**Revision 6** (`a044efa`). An erratum only, found during implementation: the belts and the ceiling
do not park together under suspension, so auto-apply is not the pocketed rider's mechanism and the
automatic retry's gate blocks the headline scenario. Recorded without a fix, deliberately.

**Revision 7** (`39ab494`, **never pushed**). Attempted to close revision 6's hole with a one-time
reclassification of `.mayRejoin` on the scene edge. Went to the three-reviewer gate and all three
returned REVISE; one implemented the mechanism and ran the headline scenario, producing
`FINAL_PHASE=unavailable(mayRejoin) AUTO_RETRIES=0`. Refuted by execution rather than by argument.
The document is not in this repository — the findings survive in the ROH-161 Linear issue and are
summarised in §The automatic retry, and why it is cut.

**Revision 8.** PO decision, 2026-08-29: **cut the automatic retry.** Four revisions failed to find
a signal that says, at a scene edge, whether an in-flight attempt will produce a map — and the
subsystem is deliberately built so that signal does not exist. The rider's loss is one tap, because
the offer button already covers both terminal cases. Three consequences:

1. The automatic-retry goal is dropped rather than failed again; a new goal replaces it — a rider is
   never offered a button that cannot succeed.
2. `Retryability` gains `.futile` for the upgrade re-render failure, which was routed to
   `.mayRejoin` only to suppress the automatic retry and would otherwise have become a dead button.
   This is the one behavioural change the cut introduces. **Dropped in revision 9** — the premise
   was false and the case was unreachable.
3. `AttemptOrigin.automatic` and the presenter's arming machinery are deleted, along with their
   tests. Tasks 1–2 otherwise survive intact.

The `humanizer` notes carried by revisions 1–5 are removed. This repository's `CLAUDE.md` excludes
specs from that skill outright, so their absence was never a gap to record.

**Revision 9.** The reconciliation of revision 8's spec gate — three independent reviewers, skeptic,
architecture and product lenses. The PO's decision to cut the automatic retry stands; two things
revision 8 said about it do not.

1. **The impossibility argument is withdrawn.** A reviewer changed one predicate in the consume
   gate and the headline scenario fired (`AUTO_RETRIES == 1`). Revision 7's failure was evidence
   against reclassifying on the scene edge, not against the mechanism. `isRunning` is public, so
   "built so that it cannot know" was also wrong about the type. §The automatic retry now carries
   the cost argument, which is what the decision actually rests on.
2. **`.futile` is dropped**, refuted independently by all three reviewers: unreachable as specified
   (no `ShareUpgradeResult` case, `phase` is `private(set)`), and built on a determinism claim
   `RideCardRenderer` contradicts — it fails on `ImageRenderer`, encode or write, none of them a
   function of the raster, and the same renderer succeeded on the fallback moments earlier. The
   free alternative — leave it on `.mayRejoin` — was mispriced as a seam change.

Defects the gate found that predate revision 8, all fixed here:

3. **§The presenter asserted a `defer` that does not exist and a no-op-when-in-flight rule that
   contradicts §One rider-visible attempt**, with §Testing asking for a test of each. Following
   that list would have added the guard and produced a dead button on the commonest path.
4. **ROH-186: the minimum dwell did not exist in production** — measured 10.8 ms against 1000 ms.
   Fixed on this branch, with a test whose timer honours cancellation.
5. **The generation guards had no coverage.** Deleting both left 16/16 green, because the stale
   attempt parked on the newer attempt's dwell gate and never reached the guard.
6. **A committed test was flaky at 35%** — `settle()`'s twelve yields are not a quiescence bound.
7. **The app target had not compiled for 13 commits.** `SlotOutcome` landed with no app-side
   caller update; the `ShareMapOutcome` seam (Task 3) is what makes Task 1 compile.
8. **Every `SharePipelineSlot.swift` citation was stale by ~32 lines**, including the two this
   document leans on immediately after retiring a bad citation, and both belt line numbers were
   wrong in both tables that give them. All re-verified against the committed source.
9. **The announcement rule** widened in revision 8 fires twice on a single attempt with no rider
   action; narrowed, and the copy requirement stated.
10. **The "cold cache" claim is over-general** — cancellation past the render is a deliberate no-op,
    so the pocketed rider's outcome is nondeterministic. Device-pass item 5 records which of two
    states it sees rather than asserting one.

**Still open, for the PO.** §Problem says the rider's real loss is *"I do not know that trying again
on wifi would very likely work"*, and §Copy forbids every sentence that would say so. Under revisions
2–8 the app closed that gap by acting; with the automatic retry gone it can only close it by telling.
The product reviewer proposes one caption under the button after a failed rider-initiated attempt —
"Works best on wifi" or similar, no apology and no error styling, one `Text` in an already-reserved
row. Not built: it is a scope addition to a descope and the call is the PO's.
