# Share-map upgrade: a rider's deadline and a terminal state (ROH-161) — design

Date: 2026-08-05
Issue: [ROH-161](https://linear.app/rohun/issue/ROH-161/share-map-upgrade-fails-silently-one-attempt-no-terminal-state-no)
Phase 2: [ROH-176 — typed provider outcome, then retry](https://linear.app/rohun/issue/ROH-176/give-the-share-map-provider-a-typed-outcome-then-build-retry-on-it) ·
Spun out: [ROH-177](https://linear.app/rohun/issue/ROH-177/a-failed-fallback-card-render-leaves-share-dead-with-no-explanation) ·
[ROH-178](https://linear.app/rohun/issue/ROH-178/share-sheet-detection-asks-is-any-modal-up-so-the-history-path-may)
Related: ROH-126 (`2026-07-29-roh126-share-card-redesign-design.md`,
`2026-07-30-roh126-slot-watchdog-cancellation.md`) · ROH-155
(`2026-07-31-share-prefetch-ownership-design.md`)
Status: **revision 3**, after three adversarial review rounds. Scope is smaller than every prior
revision.

> Process note: CLAUDE.md requires prose deliverables to go through `humanizer`. Not installed on
> this machine, so this has not had that pass.

## Scope

Replace a vanishing spinner with a line that stays, and let a late success land on its own.

- A **presentation deadline** that bounds the rider's wait, and does not cancel the pipeline.
- An **informational terminal line** when the wait ends without a map.
- **Auto-apply** when a success arrives late.

Not here: retry (ROH-176), and — new in revision 3 — **no disk-cache re-probe**. See "What the third
gate cut."

## What the three gates changed

Recorded because two of the three rounds killed a mechanism rather than a sentence, and because the
same drafting error recurred across rounds.

**Round 1 and 2 killed the retry.** `SharePipelineSlotTests.swift:256-275`
(`testSameKeyRetryDuringUnwindJoinsTheDyingPipeline`) already documents that a same-key retry against
a *cancelled* pipeline joins it and inherits its nil. That, plus the fact that `nil` from the provider
means four different things, moved retry to ROH-176. *(Narrowed in round 3: the test covers a
cancelled pipeline, so it does not by itself prove a retry against a live pipeline fails. The
four-meanings argument is the one that holds, and ROH-176 carries it.)*

**Round 2 killed the suspension argument.** Revision 1 claimed the belts and the deadline park
together so a pocketed phone unlocks to a finished card. See D6 for what actually happens.

**Round 3 killed the disk-cache re-probe**, which revision 2 introduced as retry's replacement.

**A recurring drafting failure, stated so it stops.** Three rounds each caught a claim that failed on
arithmetic or on a timeline I had not walked: revision 1's "4 s + 6 s usually lands before 7 s"
(10 > 7); revision 2's "~1.5 s on wifi" quoted from a sentence that also says "~8 s as a *cold
simulator* number" (`2026-07-31-share-prefetch-ownership-design.md:67-68`, and 8 > 7); and revision
2's re-probe, justified by a case that occurs 13 s after its own trigger has passed. Every number in
this revision is checked against its source in context, and D3 now states both numbers.

## What the third gate cut, and why

Revision 2's D7 re-read the composited disk cache — on entering the terminal state and on foreground
— to recover the case where a slot ceiling hands *this caller* nil while the pipeline runs on and
caches an accepted raster (`ShareMapSnapshotter.swift:249-251` keeps that write deliberately
un-gated).

Two independent findings killed it.

**It has no legal implementation inside this issue's scope.** `ShareMapRasterProviding` has exactly
one method (`ShareMapRasterProviding.swift:19`), and the cache is `private let` with its directory
literal in one place (`ShareMapSnapshotter.swift:137-139`). So the options are: add a seam method,
which is a provider-API change and therefore ROH-176; call `raster(for:)`, which commits the
exclusive slot on a miss and re-opens the ROH-155 question; or duplicate the directory literal in the
view, with no test binding the two copies. Revision 2 cited `:150` as proof the read was safe — but
`:150` and `:155` are in the same function, so the view cannot reach the fast path without also
reaching the slot.

**It does not fix the case it was justified by.** The ceiling is 20 s
(`SharePipelineSlot.swift:74`); the deadline is 7 s. In the ceiling scenario the nil arrives ~13 s
after the line appeared and the raster is cached a second or so later — by which time the terminal-entry
probe has long since missed, and the only remaining trigger is the rider happening to background and
return.

**Where it belongs instead: ROH-176.** "You stopped waiting; work continues" is one of the four facts
that issue's typed outcome introduces. Once the provider can *say* that, it can also hand back a
completion to await — which is a real fix rather than a poll that misses. Recorded there.

So phase 1 leaves that case unfixed, and says so rather than shipping a mechanism that appears to
address it.

## Problem

The summary renders a polyline fallback card, then upgrades it with a map raster. While that runs a
quiet "Adding your map…" hint shows (`RideSummaryView.swift:107-114`). On a reject the hint
disappears and nothing else changes.

**One attempt per presentation.** `.task` is guarded by `guard ride.stats != nil, shareImage == nil`
(`:133`), and `shareImage` is non-nil once the fallback renders. No `scenePhase` handler.

**No terminal state.** `ShareMapSnapshotter` emits nine `share-map reject:` lines
(`:176,208,218,224,232,245,285,288,295`) — one of which, `:224`, covers four causes in a single string
— plus the slot's ceiling log. All to Console, for a developer.

**No rider-facing bound.** The ceiling is 20 s (`SharePipelineSlot.swift:74`), and a waiter watching
other keys finish arms a fresh ceiling each time round its loop (documented at `:24-27`), so the wait
is not bounded at 20 s in the multi-key case.

## D0 — What is lost, and what is not

When the fallback renders, the rider holds a complete shareable card, and a failed upgrade never takes
it away. That is what makes the terminal line an observation rather than an error.

Two corrections from round 2, kept because revision 1 got both wrong. Share is **not** enabled from
the first frame — `shareImage` is assigned inside `.task` at `:141`, after `Task.yield()` and an
awaited render, and enablement is at `:89-105` where `shareImage == nil` renders
`Button("Share") {}.disabled(true)` (`:101`). And there **is** a path where Share stays disabled
forever, which the code states at `:143-144`: "No fallback, no upgrade: Share stays disabled." That is
a genuinely silent failure, it is not this issue's, and it is ROH-177 rather than a shrug.

## D1 — This reverses a recorded decision

ROH-126 §Share flow item 5 (`2026-07-29-roh126-share-card-redesign-design.md:265-268`) accepted the
cost in writing: "the residue is accepted rather than blocking Share or adding retry UI. Weak coverage
→ fallback every time — accepted; a later History open upgrades."

Phase 1 still adds no retry UI, so it keeps most of that call. What it stops doing is staying silent —
because "a later History open upgrades" only mitigates for a rider who knows to go looking, and
nothing tells them.

## D2 — Framing: an observation

The line says what the rider has, plainly. No destructive colour, no warning glyph, no "failed" —
nothing is broken. And no promise: revision 1's offer framing implied a tap, and phase 1 has no
honest tap.

## D3 — The deadline, with both numbers

A new constant, order of **7 s**, bounding how long the rider waits.

| Bound | Value | Whose job |
| --- | --- | --- |
| Slot ceiling | 20 s (`SharePipelineSlot.swift:74`) | Stop **one caller** waiting on one pipeline |
| Style belt | 4 s (`ShareMapSnapshotter.swift:268`) | Bound one SDK style load |
| Render belt | 6 s (`ShareMapSnapshotter.swift:352`) | Bound one SDK render |
| **Presentation deadline** | **~7 s, new** | **Stop the rider waiting** |

The ceiling and the deadline share a purpose and differ in scope — `SharePipelineSlot.swift:17-20`
says "the ceiling's job is to stop making a caller wait on any ONE pipeline," and `:28-32` says it
does *not* recover from a wedge. The deadline stops *the rider* waiting on *the screen*.

**Both timing numbers, in context.** `2026-07-31-share-prefetch-ownership-design.md:67-68` records
"~8 s as a *cold simulator* number and ~1.5 s on device," and `RideSummaryView.swift:374-375` puts the
device case at "~1.5 s after the summary appears" on wifi. Under contention ROH-155 measured 2.18 s
(`RideSummaryView.swift:161-163`). So 7 s is roughly four times the healthy device case, above the
contended case, and **below the cold-simulator figure** — meaning on a cold simulator the line will
often appear before a success that was coming. That is a known and accepted simulator artefact, not a
device claim.

**What the rider actually waits.** The deadline starts when `isUpgrading` flips (`:173`), after the
0.8 s sleep, which itself follows `Task.yield()` and an awaited fallback render (`:134-142`). So the
rider-visible bound is ~7.8 s plus that render, not 7 s. Stated because a section about honest bounds
should not round its own away.

**Clock choice, not hedged:** measure the deadline against `ContinuousClock`, matching the ceiling
(`SharePipelineSlot.swift:79`). A locked phone should not hold the line off — see D6.

## D4 — The deadline must not cancel `raster(for:)`

Two reasons, in order, and the first is corrected from revision 2.

**It would buy nothing.** Revision 2 claimed a cancelling deadline yields a caller that never
returns. It does return — at the ceiling, via `:129-134` (owner) or `:110-111` (waiter). The accurate
claim is that cancelling gains no time at all: the caller still returns no sooner than 20 s, so the
hint would stay up for 20 s and the deadline would be decorative. The `ceilingArm` is an unstructured
`Task {}` (`:148`), so caller cancellation does not reach it either.

**It would destroy work worth keeping.** Cancellation only ever stops a stage from *starting*
(`ShareMapSnapshotter.swift:160-178`), so a late cancel throws away a style load, a render and the
cache write, and there is no negative cache (`:100-105`) to soften the next request.

## D5 — Auto-apply

When a success arrives after the deadline, the card upgrades and the line clears. The healthy case
resolves in ~1.5 s, so this matters for the slow-but-successful middle — a pipeline landing at 9 s on
a weak connection.

The swap goes through the existing `applyOrDeferUpgrade` (`:376-382`), which holds an upgrade back
rather than swapping under a presented share sheet — behaviour the 2026-07-31 device pass established
the hard way (`:370-375`). D9 is what stops that deferral from becoming a lie.

## D6 — What suspension actually does

Revision 1 claimed suspension helped. Revision 2 corrected the outcome but named the wrong cause
("the render belt fires overdue"), which contradicted its own statement that `DispatchTime` does not
advance while asleep. Both are now replaced by the mechanism.

The belts are `DispatchQueue.main.asyncAfter` (`ShareMapSnapshotter.swift:268,352`), so they do not
advance while the machine sleeps. The ceiling is `Task.sleep(for:)` on `ContinuousClock`
(`SharePipelineSlot.swift:79`), so it does. So after a long screen-lock, on resume:

1. The ceiling has already expired. Its arm resolves, `task.cancel()` fires (`:132`).
2. That cancellation reaches the render's `onCancel`, which cancels the snapshotter and resolves its
   latch nil (`ShareMapSnapshotter.swift:359-370`).
3. The provider returns nil. Nothing is cached.

**The render is killed by the ceiling's cancellation, not by an overdue belt.** And the deadline,
also on `ContinuousClock`, has expired too — so the line is on screen at the first frame after unlock,
which is the correct outcome and the reason D3 pins the clock.

A *short* lock changes nothing: no bound has expired, and the spinner resumes mid-flight. That is
honest.

So the pocketed-phone rider gets a truthful line and no map. Better than a vanishing spinner, and
worse than revision 1 promised. Phase 1 does not fix it; ROH-176 can.

## D7 — The reducer is total, and that is the design

The whole of phase 1's correctness rests on one property: **every input is legal in every phase, and
a late or duplicate input is a no-op by construction.**

That is what takes task lifetime off the correctness path. Revision 2 staked the deadline task's
behaviour on being `@State`-held and cancelled in `.onDisappear` — but `RideHUDView.swift:346`
records that `onDisappear` "can fire without the rider asking for anything," so a design that needs
it to be precise is a design built on a signal this repo has already written off. With a total
reducer, a deadline that fires after the view settled is simply an input the reducer ignores, and the
task's shape becomes a performance question.

**Inputs:** deadline reached · provider produced a raster · provider produced nothing · upgrade render
produced a card · upgrade render produced nothing · the card was applied · the card was deferred.

**Phases:** `upgrading` · `successPending` (a raster is in hand, its card is not) · `upgraded` (a card
is on screen) · `settledOnFallback` (the line is showing).

`absent` is not a phase. No route, no stats and no fallback are preconditions resolved before the
machine exists (`:145-147`), and revision 2 was wrong to list it alongside transitions.

## D8 — Terminal is input-scoped, not phase-scoped

Revision 2 said the terminal phase is "enterable only from the upgrading phase." That contradicted its
own D11, which requires a failed upgrade render to settle on the fallback — a transition out of
`successPending`, exactly what the rule forbade. Both appeared in the same test list.

The rule that works names the input:

- **The deadline input** enters `settledOnFallback` only from `upgrading`. Once a raster is in hand,
  the deadline is a no-op — this is what stops a success at 6.9 s from flashing a line while its card
  renders.
- **The render-failure input** enters `settledOnFallback` from `successPending`. A raster that renders
  no card leaves the fallback on screen, so that is what the phase must say.
- **A provider-nothing input** enters `settledOnFallback` from `upgrading`, at the moment it arrives —
  a reject at 2 s shows the line at 2 s, not at 7 s.
- **From `settledOnFallback`**, a later provider or render success still moves forward (that is
  auto-apply). A later *nothing* is a no-op.

## D9 — `upgraded` means applied, so the defer latch is an input

The gate's sharpest finding, and it would have rebuilt ROH-161's defect inside the fix.

`applyOrDeferUpgrade` (`:376-382`) writes `deferredUpgrade` instead of `shareImage` when a share sheet
is up. A machine keyed on the *render* outcome would call that `upgraded` and clear the line — while
the card on screen is still generation 0. Silent no-map with nothing saying so.

So the reducer takes **applied** and **deferred** as distinct inputs. Deferred holds `successPending`;
the release at `:407-411` supplies **applied**, which is what reaches `upgraded`.

This also makes phase 1 degrade honestly under ROH-178. If `shareSheetUp` is stuck true for the
History sheet's whole lifetime, the machine stays at `successPending` — spinner up, no false claim —
rather than announcing a map the rider does not have. Wrong, but wrong in the direction that does not
lie.

## D10 — The copy names no reason

Nine log lines, and no action to take in phase 1. Naming a reason costs nine strings and buys nothing,
and "the style source failed to load" is not a sentence for someone standing over a bike.

`ShareMapSnapshotter.swift:116-120` still says "a nil from this pipeline is invisible in the UI by
design." That premise is what this issue deletes, and the comment is part of the work.
`RideSummaryView.swift:139`'s "Share is enabled from the first frame" is wrong (D0) and gets fixed in
the same pass.

## D11 — Nothing re-opens ROH-155

Phase 1 makes no request. The deadline starts after the 0.8 s sleep and its cancellation guard
(`:170-173`), and with the re-probe cut there is no other entry point. So the sleep keeps all three
documented jobs and a History glance still commits no pipeline.

This was false in revision 1 (retry) and shaky in revision 2 (the re-probe could reach the slot). It
is true here because both are gone.

## D12 — Where it lives, and what stays in the view

The reducer goes to **AuraKit** (`Sources/AuraKit/Sharing/`, beside `ShareCardContent` and
`ShareRasterAcceptance`). The app target has no unit test target — `Aura/project.yml` declares only
`Aura`, `AuraWidgets`, `AuraUITests` — and `ShareMapSnapshotter.swift:122-128` records what that cost
this exact subsystem: the slot "used to live inline here, where the app target's lack of any
unit-test target put it out of reach of a test — which is where the review found the ceiling arm
clearing the slot out from under a live pipeline."

Small: four phases, seven inputs, one transition function.

**`isUpgrading` is derived** from the phase (`upgrading` or `successPending`). It is read once, at
`:182`.

**`showHint` stays as state.** Revision 2 said to derive it; that is not implementable. The phase does
not change at t+0.3 s, so deriving the show-delay needs a second time input, a second timer, and a
second late-fire hazard — and dropping the delay reintroduces the warm-cache flash `:174-179` exists
to prevent, on the History path where warm hits actually happen. The reducer must never write it.

**Also staying in the view, untested:** the deadline task's shape, the sheet latch, and the `@State`.
One note for the plan: the existing `hint` Task (`:180-184`) is a trap, not a precedent. A `Task {}`
inside `.task` is unstructured, so view cancellation does not reach it; its `try?` swallows
`CancellationError`, which is why `:182` re-checks `Task.isCancelled`. A deadline task needs the same
guard after every await. Structured alternatives do not help: a task group awaits its children at
scope exit and the raster child's cancellation is a no-op, so the group would sit until the pipeline
ends.

## Risks

**The line makes riders wait to share who otherwise would not have.** Untestable off-device.

**Layout shift under a travelling thumb.** The line goes where the hint is (`:107-114`), directly
above `Button("Done")` (`:117`), and auto-apply removes it later — moving Done twice.

**ROH-178 degrades this feature.** D9 makes the degradation honest rather than a lie, but on the
History path a stuck `shareSheetUp` means a spinner that never resolves. Worth sequencing ROH-178
first if it verifies.

**7 s is above the contended device case and below the cold-simulator case.** D3.

## Out of scope

Retry and the typed provider outcome (ROH-176). The disk-cache re-probe, and with it the
ceiling-nil-with-a-cached-raster case (ROH-176). The fallback-render silent failure (ROH-177). The
share-sheet predicate (ROH-178). The 20 s ceiling. Blocking or gating Share. Negative caching. Naming
reject reasons. Any change to when a raster is requested, to the prefetch, or to slot ownership. The
already-shared-file residue, which ROH-126 accepted.

## Testing

The reducer, in `AuraKitTests`. The first test is the one that matters:

- **Totality:** every input in every phase yields a defined phase and never traps.
- Deadline in `upgrading` → `settledOnFallback`. Deadline in `successPending` → no-op (D8's flash
  race). Deadline in `upgraded` or `settledOnFallback` → no-op (the late-fire case).
- Provider raster → `successPending`, from `upgrading` **and** from `settledOnFallback` (auto-apply).
- Provider nothing in `upgrading` → `settledOnFallback` immediately. In any other phase → no-op.
- Render card + **applied** → `upgraded`. Render card + **deferred** → stays `successPending` (D9).
- Render nothing in `successPending` → `settledOnFallback` (D8).
- Duplicate inputs: applied twice, deadline twice, nothing-then-raster → no wrong phase.

*(Dropped from revision 2: "no cancellation" and "no stacking" — a pure reducer can observe neither,
and non-stacking is `SharePipelineSlot`'s property, already covered by its own tests.)*

Device pass, on a real phone:

- **Swap-while-sheet-open**, load-bearing rather than a named risk now that auto-apply makes it
  routine: present the sheet, land an upgrade under it, confirm the sheet neither dismisses nor
  changes payload, **and** that the deferred upgrade is eventually applied — on both the push and
  History paths. This is where ROH-178 will show itself.
- **Airplane mode at ride end** → line appears, stays, and Share still works.
- **Lock through the whole window** → line on screen at unlock, no spinner (D6).
- Whether 7 s feels right, and whether Done moving is a mis-tap hazard.

## Open questions

1. What does the line say? D2 fixes its job, not its words.
2. Is 7 s right on device?
3. Should ROH-178 land first, given it can pin this feature's spinner on the History path?
