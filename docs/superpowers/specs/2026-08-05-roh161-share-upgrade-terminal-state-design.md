# Share-map upgrade: a rider's deadline, a terminal state, and a card that catches up (ROH-161) — design

Date: 2026-08-05
Issue: [ROH-161 — Share-map upgrade fails silently: one attempt, no terminal state, no retry](https://linear.app/rohun/issue/ROH-161/share-map-upgrade-fails-silently-one-attempt-no-terminal-state-no)
Related: [ROH-126](https://linear.app/rohun/issue/ROH-126/redesign-shareable-post-ride-card-real-map-background-distance-off-the)
(`2026-07-29-roh126-share-card-redesign-design.md`, and the watchdog follow-up
`2026-07-30-roh126-slot-watchdog-cancellation.md`) ·
[ROH-155](https://linear.app/rohun/issue/ROH-155/share-map-prefetch-cancel-authority-follows-arrival-order-and-the)
(`2026-07-31-share-prefetch-ownership-design.md`)
Status: **revision 2**, following a two-lens adversarial gate (`review-skeptic`,
`review-architecture`) on 2026-08-05. Revision 1's retry design does not work; the scope is now
narrower and the retry is a separate issue.

> Process note: CLAUDE.md requires prose deliverables to go through `humanizer`. It is not
> installed on this machine, so this spec has not had that pass. Recorded rather than skipped.

## What the gate changed

Revision 1 proposed a deadline, a terminal *offer*, unbounded retry, and auto-apply. Both reviewers
refuted the retry independently, and one found a checked-in test that says the opposite of what the
spec claimed. Every finding below was re-verified against the code before being accepted.

**The retry does not work, and `SharePipelineSlotTests.swift:256-275` already documents why.** The
test is named `testSameKeyRetryDuringUnwindJoinsTheDyingPipeline`; its own doc comment says an
architecture reviewer reproduced it, and it asserts `"the retry inherits the cancelled pipeline's
nil"` and `"does not run a second pipeline for a live key"`. So a tap while the original pipeline is
alive joins it and inherits its nil — and returns fast enough that the 300 ms show-delay never fires,
so the rider sees no change at all. Revision 1 also contradicted itself here: D5 said the tap "joins
the pipeline still running, **or starts a fresh one**," D7 said "every retry is a **genuine fresh
attempt**." Both cannot be true, and the test settles which is false.

**The suspension argument was backwards, and it was the justification for auto-apply.** The render
belts are `DispatchQueue.main.asyncAfter` (`ShareMapSnapshotter.swift:268,352`), i.e. `DispatchTime`,
which does *not* advance while the machine sleeps. The slot ceiling is `Task.sleep(for:)`
(`SharePipelineSlot.swift:79`), i.e. `ContinuousClock`, which does. This repo documents that exact
distinction in that exact scenario at `RideInstant.swift:31-35` — "a phone in a jersey pocket with
the screen locked is exactly where a suspending clock under-counts." So on resume the render belt
fires *overdue*, rejecting a render that never had CPU, and there is no negative cache: the rider
gets a rejection and a cold cache. Revision 1 claimed they would "unlock to a finished map card."

**`nil` from the provider is four different facts**, and `UIImage?` cannot tell them apart:
rejected permanently, rejected transiently, *you* stopped waiting while the pipeline lives on and may
still cache a map, and you joined a dying pipeline. D8 below turns on this.

**Provider success is not an upgraded card.** `RideCardRenderer.make` returns nil on three paths —
renderer produced nothing, PNG encode failed, atomic write failed (`RideCardRenderer.swift:30,37,46`)
— so revision 1's phase machine would have reported `upgraded` with the fallback still on screen,
reproducing ROH-161's own defect inside the fix.

**"Strictly downstream of ROH-155" was false**, because `RideSummaryView` is also the History sheet
(`HistoryView.swift:53`) and a retry button there is a new uncapped, undebounced, uncancellable
request path into the exclusive slot — verbatim the failure ROH-155 was closed over.

Also corrected: D0's citation was wrong and its claim overstated (see D0); the ceiling's job was
misattributed in D3's table; D3's cancellation argument was borrowed from a comment about a different
question (see D4); the 7 s justification was a non-sequitur (4 + 6 = 10 > 7); and two listed unit
tests asserted properties a pure function structurally cannot exhibit.

## The split

**This issue (phase 1):** the presentation deadline, a terminal state, auto-apply, and a **disk-cache
re-probe on foreground**. No retry button. Nothing touches the provider API, the slot, or when a
request is made.

**A new issue (phase 2):** give `ShareMapRasterProviding` a typed outcome instead of `UIImage?`, and
build retry on top of that. Every confirmed defect in revision 1 lives in the retry path, and all of
them are downstream of one overloaded `nil`. Fix the vocabulary first and retry becomes small; build
it on `UIImage?` and it is a button that lies.

**Stated cost of the split:** the terminal state becomes *informational* rather than an offer. An
offer implies an action, and the action cannot be made honest in phase 1. This is a real reduction
from what was approved on 2026-08-05, and it is the part of this revision most worth arguing with.

## Problem

The summary renders a polyline fallback card, then tries to upgrade it with a real map raster. While
that runs, a quiet "Adding your map…" hint appears (`RideSummaryView.swift:107-114`). On a reject the
hint disappears and nothing else on screen changes.

**One attempt per presentation.** The `.task` is guarded by
`guard ride.stats != nil, shareImage == nil` (`:133`) and `shareImage` is non-nil the moment the
fallback renders. There is no `scenePhase` handler.

**No terminal state.** `ShareMapSnapshotter` emits nine distinct `share-map reject:` lines
(`:176,208,218,224,232,245,285,288,295`), plus the slot's ceiling log — all to Console, for a
developer. Note one of those nine is not itself distinct: `:224` covers four causes in one string
("render failed, timed out, mid-render error, or no captured route"), so revision 1's "every reject
path logs a distinct reason" was slightly generous.

**No bound on the rider's wait.** The slot ceiling is 20 s (`SharePipelineSlot.swift:74`) and a
waiter that watches other keys finish arms a fresh ceiling per loop iteration
(`SharePipelineSlot.swift:144-148`), so the wait is not even bounded at 20 s in the multi-key case.

The two commonest ways a rider loses the map: offline or weak signal at ride end, and the phone
pocketed during the window.

## D0 — What is lost, corrected

Revision 1 said "Share is enabled from the first frame (`RideSummaryView.swift:139-145`)." Both
halves were wrong.

- The citation is wrong. `:139-145` is the fallback render; Share's enablement is `:89-105`, where
  `shareImage == nil` renders `Button("Share") {}.disabled(true)` (`:101`).
- "From the first frame" is false: `shareImage` is assigned inside `.task` at `:141`, after
  `await Task.yield()` (`:134`) and an awaited render. Share is disabled for the first several frames.
- **There is a path where Share stays disabled forever**, and the comment two lines below the range
  revision 1 quoted says so (`:143-144`): "No fallback, no upgrade: Share stays disabled."

So the corrected claim is narrower: **when the fallback renders, the rider has a complete shareable
card, and a failed upgrade never takes it away.** That is what makes the terminal state an
observation rather than an error.

The fallback-render failure is a genuinely silent failure — a dead grey Share button with no
explanation. Revision 1 filed it under "unchanged from today," which is a contradiction in a spec
whose thesis is that silent failure is the bug. It is out of scope here (it is a different failure,
with a different remedy) and it gets its own issue rather than a shrug.

## D1 — This reverses a recorded decision

ROH-126 §Share flow item 5 (`2026-07-29-roh126-share-card-redesign-design.md:265-268`) accepted this
cost in writing: "the residue is accepted rather than blocking Share or adding retry UI. Weak
coverage → fallback every time — accepted; a later History open upgrades."

ROH-161 revisits it because two reviewers independently ranked it above ROH-155's work, and ROH-155
was then closed won't-do with this named as what to build instead. What changed is not the cost but
the confidence that "a later History open upgrades" is a mitigation — it only mitigates for a rider
who knows to go looking, and nothing tells them.

Phase 1 partially *keeps* ROH-126's call: still no retry UI. What it stops doing is staying silent.

## D2 — Framing: an observation, not an error and not an offer

The terminal line says what the rider has, in plain language, with no destructive colour, no warning
glyph, and no "failed". Nothing is broken: the card is finished and shareable.

It also does not promise anything. Revision 1's offer framing ("try for the detailed one") implied a
tap; phase 1 has no honest tap. Copy that promises an action the build cannot deliver is worse than
copy that states a fact.

Rejected, unchanged from revision 1: an error framing tells the rider they have a problem they mostly
do not have, on the screen whose job is "nice ride," and it reads dishonestly at the deadline, where
nothing has failed yet.

## D3 — The presentation deadline is a fourth bound, and it is the rider's

A new constant, order of **7 s**, whose only job is to bound how long the rider waits.

| Bound | Value | Whose job |
| --- | --- | --- |
| Slot ceiling | 20 s (`SharePipelineSlot.swift:74`) | Stop making **one caller** wait on one pipeline |
| Style belt | 4 s (`ShareMapSnapshotter.swift:268`) | Bound one SDK style load |
| Render belt | 6 s (`ShareMapSnapshotter.swift:352`) | Bound one SDK render |
| **Presentation deadline** | **~7 s, new** | **Stop the rider waiting** |

*(Corrected: revision 1's table said the ceiling protects a singleton from a wedged pipeline, which
contradicted the quote revision 1 used five lines later and is refuted by the source.
`SharePipelineSlot.swift:17-20` says "the ceiling's job is to stop making a caller wait on any ONE
pipeline," and `:28-32` says explicitly that it does **not** recover from a wedge: "a pipeline that
ignores it holds the slot for the life of the owner, and every later caller then pays a full ceiling
to be told nil.")*

So the ceiling and the deadline share a purpose and differ in scope: the ceiling stops *a caller*
waiting on *a pipeline*; the deadline stops *the rider* waiting on *the screen*. That is a weaker
distinction than revision 1 drew, and it is the true one.

**On 7 s.** Revision 1 argued it was "long enough that a healthy pipeline (4 s style belt plus 6 s
render belt in the worst case) usually lands first," which is self-refuting: 4 + 6 = 10 > 7, and
`ShareMapSnapshotter.swift:105` calls it "the ≤10 s pipeline" with acceptance, composite, encode and
prune unbounded past that. The honest justification is empirical, not structural: ROH-155 records the
upgrade resolving in about 1.5 s on wifi, and `RideSummaryView.swift:374-375` puts it at "~1.5 s after
the summary appears." 7 s is several multiples of the healthy case and well under the ceiling. It is a
guess bounded by one measurement, it is injectable, and the device pass is what settles it.

## D4 — The deadline must not cancel `raster(for:)`, and here is the actual reason

Revision 1 imported `cancelledBeforeStarting`'s doc comment (`ShareMapSnapshotter.swift:161-178`) as
its authority. That comment argues about *where inside the pipeline to place cancellation checks* —
it is not an argument that a caller must refrain from cancelling, and the slot's own ceiling does
cancel (`SharePipelineSlot.swift:132`). Borrowing it was a category error.

The real reason is in the file revision 1 cited elsewhere, at `RideSummaryView.swift:155-158`:

> `slot.run` has NO cancellation point — both its awaits go through `withCheckedContinuation` and the
> pipeline task is unstructured — so a cancelled caller neither returns nor frees the slot.

Confirmed: `SharePipelineSlot.race` awaits a `withCheckedContinuation` and a non-throwing
`Task.value`, neither a cancellation point (its own doc says so at `:140-143`), and the pipeline is an
unstructured `Task {` at `:117`.

**So a cancelling deadline would produce a caller that never returns** — the `.task` never reaches
`isUpgrading = false` (`:194`), and the hint never clears. A permanent spinner: exactly the defect
this issue exists to remove. The secondary argument from revision 1 still holds and is worth keeping
(a late cancel would throw away a style load, a render and the cache write, with no negative cache to
soften it), but it is the secondary one.

The deadline changes what is on screen and nothing else.

## D5 — Auto-apply, on honest grounds

When a success arrives after the deadline, the card upgrades itself and the terminal line disappears.

Revision 1 justified this with the suspension claim, which was backwards. The justification that
survives is smaller and still sufficient: **a success that lands while the rider is still on this
screen should not require a tap**, and there is no tap in phase 1 to require. The healthy case
resolves in ~1.5 s, so this mostly matters for the slow-but-successful middle: a pipeline that lands
at 9 s on a weak connection.

The swap goes through the existing `applyOrDeferUpgrade` (`:376-382`), which holds an upgrade back
rather than swapping the item under a presented share sheet — behaviour the 2026-07-31 device pass
established the hard way (`:370-375`).

## D6 — What suspension actually does

Recorded because revision 1 got it backwards and the corrected version is a limitation, not a
feature.

The belts are `DispatchTime`-based and do not advance while the machine sleeps. The ceiling — and the
deadline, if built on `Task.sleep` — is `ContinuousClock` and does. Consequences on resume from a
long screen-lock:

- The deadline has **already expired** in continuous time, so the terminal line is on screen at the
  first frame after unlock.
- The render belt fires **overdue**, rejecting a render that never had CPU.
- With no negative cache, nothing is cached.

So the pocketed-phone rider gets a truthful line and no map. That is better than today's vanishing
spinner and worse than revision 1 promised. D7 is what recovers the recoverable part of it.

## D7 — A disk-cache re-probe on foreground

Phase 1's one new mechanism, and the piece revision 1 was missing while its own Problem section
complained that no `scenePhase` handler exists.

On returning to the foreground, and once on entering the terminal state, re-read the disk cache for
this request's key. If an image is there, apply it and clear the line.

Why this earns its place:

- **It fixes the case both reviewers hit hardest.** A ceiling hands *this caller* nil while the
  pipeline runs on and caches the result — `ShareMapSnapshotter.swift:249-251` records that the cache
  write is deliberately not cancellation-gated, because "an accepted raster is worth keeping." So a
  perfectly good map can land in `Caches/ShareCardSnapshots` moments after the rider was told nil,
  and nothing re-reads it. Auto-apply cannot fire: that caller's await already returned.
- **It is structurally safe.** A small file read, the same one `raster(for:)` already does as its
  fast path (`ShareMapSnapshotter.swift:150`). It starts no pipeline, commits no slot, and creates no
  new request path — which is what keeps D10's ROH-155 claim true.
- **It covers the pocketed phone as far as it can be covered.** If the pipeline cached before
  suspension, the rider unlocks to a finished card.

It cannot help when the pipeline genuinely rejected. Nothing in phase 1 can.

## D8 — Terminal state is entered by the deadline or a non-image outcome, whichever is first — after a re-probe

A reject at 2 s shows the line at 2 s, not at 7 s. If the deadline fires first, the line appears then.
Either way the cache is re-probed immediately before the line appears, for the reason in D7: `nil`
means "this caller stopped waiting," not "no map exists."

Once terminal, a later nil is a no-op.

**One race the phase machine must handle explicitly.** `RideCardRenderer.make` is a 1080×1350
main-actor render plus an awaited off-main encode. A success at 6.9 s yields at that await, the 7 s
deadline wakes and writes the terminal phase, and then the render lands and writes `upgraded` — a
visible flash of a line over a success that had already arrived. So the terminal phase is enterable
**only from the upgrading phase**, and observing a success moves out of upgrading immediately, before
the render is awaited. That needs a distinct "success observed, swap pending" state; four phases
cannot represent it.

## D9 — The copy names no reason

Nine log lines, and the rider can act on none of them — there is no action in phase 1 at all. Naming
a reason would cost nine strings and buy nothing, and "the style source failed to load" is not a
sentence for someone standing over a bike. The reasons keep going to the log, which is where
`ShareMapSnapshotter.swift:116-120` says they were put deliberately.

That comment's premise — "a nil from this pipeline is invisible in the UI **by design**" — is what
this feature deletes. It needs updating as part of the work, which revision 1 did not notice while
citing it as authority.

## D10 — Nothing here re-opens ROH-155, and the split is why

ROH-155 concluded that ride end and History want opposite policies on when to request a raster, that
nothing distinguishes them, and that "any change that treats them alike is wrong in one of them."

Phase 1 makes no request. The deadline starts after the 0.8 s sleep and its cancellation guard
(`:170-173`); the re-probe is a cache read. So the sleep keeps all three documented jobs and a
History glance still commits no pipeline.

This claim was **false in revision 1** and is true here only because the retry left. Phase 2 has to
answer ROH-155's question rather than inherit this paragraph — and the likeliest answer is that retry
is offered on the ride-end path only, since History already re-attempts on every open.

## D11 — Success from the provider is not an upgraded card

The phase machine's inputs must include the **upgrade render's** outcome, not just the provider's.
`RideCardRenderer.make` fails on three paths (`RideCardRenderer.swift:30,37,46`), each logging and
none surfacing, and `:187`'s `!Task.isCancelled` is a fourth way the upgrade is dropped after a
successful raster.

A raster that renders no card leaves the fallback on screen, so it is terminal, not `upgraded`.

## D12 — The phase machine, and what it can honestly own

The decision table moves to **AuraKit** (`Sources/AuraKit/Sharing/`, beside `ShareCardContent` and
`ShareRasterAcceptance`) as a pure type. The app target has no unit test target — `Aura/project.yml`
declares only `Aura`, `AuraWidgets` and `AuraUITests` — and `ShareMapSnapshotter.swift:122-128`
records what that cost this exact subsystem: the slot "used to live inline here, where the app
target's lack of any unit-test target put it out of reach of a test — which is where the review found
the ceiling arm clearing the slot out from under a live pipeline."

Inputs: elapsed-versus-deadline, provider outcome, **upgrade-render outcome** (D11), and a cache-hit
signal (D7). Phases: `upgrading`, `successPending`, `upgraded`, `settledOnFallback`, and a
non-transitioning `absent` for the no-route / no-stats / no-fallback preconditions, which are
determined before the machine exists.

**No attempt epoch is needed, and that is a benefit of the split.** With no retry there is exactly
one logical attempt per presentation, so there is no superseded attempt whose stale outcome could
demote an upgraded card. Phase 2 will need an epoch; phase 1 does not, and the spec says so rather
than discovering it later.

**What stays in the view, and stays untested:** the deadline task's lifetime, the sheet latch, and the
`@State`. Two notes for the plan, both from the gate. The existing `hint` Task (`:180-184`) is a trap
rather than a precedent: a `Task {}` created inside `.task` is unstructured, so view cancellation does
not reach it, and its only cancellation is `hint.cancel()` at `:186` — unreachable until the
uncancellable provider await returns. A deadline task copying that shape fires ~7 s after a
dismissal. It needs to be `@State`-held and cancelled in an `.onDisappear`, which this view does not
currently have. And the structured alternatives do not work: `async let` and task-group children are
nonisolated and cannot touch `@State` (the comment at `:174-176` is right about that), and a group
cannot exit early while the raster child's cancellation is a no-op.

`isUpgrading` and `showHint` should be *derived from* the phase rather than living beside it. Five
pieces of state already write to this region — `shareImage`, `isUpgrading`, `showHint`,
`shareSheetUp`, `deferredUpgrade` — and adding a sixth that can disagree with two of them is how the
hint ends up flashing over an upgraded card.

## Risks

**The line makes riders wait to share who otherwise would not have.** Even as an observation rather
than an offer, "simple map" implies something better exists. Untestable off-device.

**Layout shift at a rider-independent moment.** The line goes where the hint is (`:107-114`), directly
above `Button("Done")` (`:117`). It appears at 7 s and auto-apply removes it later, moving Done twice
while a thumb may be travelling toward it.

**`shareSheetUp` may be wrong on the History path, and auto-apply leans on it harder.**
`SharePresentation.isPresenting` (`:435-445`) asks whether the key window's root view controller has
*any* presented view controller. The History path presents this very view as a sheet
(`HistoryView.swift:53`), so the predicate may be true for the summary's entire lifetime — in which
case every upgrade after one Share tap is deferred and applied only into a dying view. Pre-existing,
promoted by auto-apply from rare to routine, and it needs its own issue rather than a line in this
one. The presentation poll is also one-shot and bounded at 2 s (`:398-401`).

**7 s is a guess bounded by one measurement.** D3.

## Out of scope

Retry, and the typed provider outcome it needs (phase 2). The fallback-render silent failure (D0) and
the `isPresenting` predicate (Risks) — both get their own issues. The 20 s ceiling, which is doing its
own job. Blocking or gating Share. Negative caching. Naming reject reasons in the UI. Any change to
when a raster is requested, to the prefetch, or to slot ownership. The already-shared-file residue: a
rider who shares at 1 s shares generation 0 and no later upgrade changes a file already handed to
Messages — ROH-126 accepted that and this does not reopen it.

## Testing

The pure phase machine, in `AuraKitTests`:

- Provider success before the deadline → the line never appears.
- Provider success after the deadline → line clears, phase reaches `upgraded`.
- Provider nil before the deadline → terminal at the nil, **not** at the deadline (D8).
- Deadline reached with no outcome yet → terminal.
- A nil arriving after terminal → no-op.
- Success at the deadline boundary → `successPending` wins; the terminal phase is not enterable from
  it (D8's flash race).
- Provider success with a failed upgrade render → terminal on the fallback, **not** `upgraded` (D11).
- A cache hit supplied at the terminal boundary or on foreground → `upgraded` (D7).

*(Revision 1 also listed "deadline fires — no cancellation" and "repeated retries — no stacking."
Both are dropped: a pure function over these inputs cannot observe cancellation or stack anything,
and non-stacking is `SharePipelineSlot`'s property, already covered in `SharePipelineSlotTests`.)*

Device pass, on a real phone:

- **Swap-while-sheet-open**, now load-bearing rather than a named risk: present the sheet, land an
  upgrade under it, confirm the sheet neither dismisses nor changes payload — **and** confirm the
  deferred upgrade is eventually applied, on both the push and History paths.
- **Airplane mode at ride end** → line appears; re-enable wifi, background and foreground the app →
  does the re-probe find anything, and is that the right expectation?
- **Lock through the entire window** → line on screen at unlock, per D6. Confirm no spinner.
- Whether 7 s feels right; whether the line flashes ahead of an imminent success; whether the Done
  button moving is a mis-tap hazard.

## Open questions

1. Is 7 s right, or does the line appear too eagerly ahead of a landing pipeline?
2. Does the auto-applied swap read as delightful or as a glitch to a rider looking at the card?
3. What exactly does the line say? D2 fixes its job — an observation about the card — not its words.
4. Phase 2's scoping question, recorded here so it is not lost: should retry exist on the ride-end
   path only, given History already re-attempts on every open (D10)?
