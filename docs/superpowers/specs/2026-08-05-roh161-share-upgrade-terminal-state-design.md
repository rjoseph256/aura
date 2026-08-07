# Share-map upgrade: a rider's deadline, a terminal state, and a way to ask again (ROH-161) — design

Date: 2026-08-05
Issue: [ROH-161 — Share-map upgrade fails silently: one attempt, no terminal state, no retry](https://linear.app/rohun/issue/ROH-161/share-map-upgrade-fails-silently-one-attempt-no-terminal-state-no)
Related: [ROH-126](https://linear.app/rohun/issue/ROH-126/redesign-shareable-post-ride-card-real-map-background-distance-off-the)
(`docs/superpowers/specs/2026-07-29-roh126-share-card-redesign-design.md`) ·
[ROH-155](https://linear.app/rohun/issue/ROH-155/share-map-prefetch-cancel-authority-follows-arrival-order-and-the)
(`docs/superpowers/specs/2026-07-31-share-prefetch-ownership-design.md`)
Status: revision 1, pre-gate.

> Process note: CLAUDE.md requires prose deliverables to go through the `humanizer` skill. It is
> not installed on this machine, so this spec has not had that pass. Recorded rather than skipped.

## Problem

The ride summary renders a polyline **fallback card** immediately, then tries to upgrade it with a
real map raster. While that runs, a quiet "Adding your map…" hint appears
(`RideSummaryView.swift:107-114`). If the pipeline rejects, the hint disappears and nothing else on
screen changes. No message, no failed state, no way to ask again.

Three separate deficiencies, and they compound.

**One attempt per presentation.** The `.task` is guarded by
`guard ride.stats != nil, shareImage == nil` (`RideSummaryView.swift:133`), and `shareImage` is
non-nil the moment the fallback renders. There is no `scenePhase` handler and no other trigger.

**No terminal state.** Every reject path logs a distinct, well-written reason — the issue names
seven categories, and `ShareMapSnapshotter` emits nine distinct log lines across them, plus the
slot's ceiling log. All of it goes to Console, for a developer. The rider gets one vanishing
spinner for all of it.

**No bound on the rider's wait.** `SharePipelineSlot`'s ceiling is 20 s
(`SharePipelineSlot.swift:78`). That is a resource watchdog protecting an app-lifetime singleton
from a wedged pipeline, and a sensible number for that job. It is also, by accident, the only thing
bounding how long a rider stares at a spinner while standing over their bike. Worse, a waiter that
watches other keys finish re-arms a fresh ceiling each time, so the wait is not even bounded at 20 s
— the slot's own doc records this as an inherited limit.

The two commonest ways a rider loses the map both land here: **offline or weak signal at ride end**,
because you finish rides where you finish them, and **the phone pocketed during the window**, which
is the normal thing to do after ending a ride.

## D0 — What is actually lost, and what is not

**Share is never blocked by a failed upgrade.** The fallback card renders first, `shareImage` is
set, and Share is enabled from the first frame (`RideSummaryView.swift:139-145`). A rider whose
upgrade fails still has a complete, shareable card.

So the loss is not "I cannot share." It is: *I got the polyline card, I was never told a better one
was attempted, and I do not know that trying again on wifi would very likely work.* That framing
drives every decision below, and it is why this is not an error-reporting feature.

## D1 — This reverses a recorded decision

ROH-126 §Share flow item 5 accepted exactly this cost, in writing:

> **Accepted cost, stated**: a rider who shares within the first seconds (or in dead coverage)
> shares the polyline fallback card. Prefetch makes this rare on the ride-end path; the residue is
> accepted rather than blocking Share or adding retry UI. Weak coverage → fallback every time —
> accepted; a later History open upgrades.

ROH-161 revisits it because two reviewers, independently, ranked it above the work ROH-155 proposed
— and ROH-155 was then closed won't-do, with "retry and terminal state on the summary upgrade"
named as what to build instead.

What changed is not the cost but the confidence that "a later History open upgrades" is a real
mitigation. It is only a mitigation for a rider who knows to go looking. Nothing tells them.

## D2 — Framing: a choice, not an error

The terminal state reads as an offer, not an apology. Nothing is broken, so nothing apologises: no
destructive colour, no warning glyph, no "failed". The card is finished; the map is an upgrade that
did not land, and the rider is offered another go.

Rejected: an error framing ("Couldn't add the map"). It tells the rider they have a problem they
mostly do not have, on the one screen whose job is "nice ride". It also makes the deadline read
dishonestly — at 7 s nothing has failed yet, the pipeline is usually still working.

Rejected: no visible affordance, retry in History only. It accepts ROH-126's original call for the
ride-end moment, and it is defensible on the grounds that a retry at the trailhead often fails again
for the same reason. But it leaves the single commonest failure — offline at ride end — as the one
case with no affordance at all.

## D3 — The presentation deadline is a fourth timeout, and it is the rider's

A new constant in the summary, order of **7 s**, whose only job is to bound how long the rider
waits. It is deliberately none of the three existing bounds, all of which serve different masters:

| Bound | Value | Whose job |
| --- | --- | --- |
| Slot ceiling | 20 s (`SharePipelineSlot.swift:78`) | Protect an app-lifetime singleton from a wedged pipeline |
| Style belt | 4 s (`ShareMapSnapshotter.swift:268`) | Bound one SDK style load |
| Render belt | 6 s (`ShareMapSnapshotter.swift:352`) | Bound one SDK render |
| **Presentation deadline** | **~7 s, new** | **Stop the rider waiting** |

ROH-126's own design note already found this separation one layer down — "the ceiling has one
legitimate job: stop making this caller wait. Freeing the slot is a different job." The same split
applies again at the UI: the rider should stop waiting long before the pipeline stops working.

**The deadline must not cancel `raster(for:)`.** The pipeline's own comments argue this at length
(`ShareMapSnapshotter.swift:161-178`): cancellation only ever stops a stage from *starting*, never
discards a finished one, precisely because a late cancel "would have saved a 90×60 downsample and
one draw, and thrown away ten seconds of style load and SDK render plus the cache write." With no
negative cache (`:100-105`), the next request would then pay the whole pipeline again. So the
deadline changes what is on screen and nothing else.

## D4 — Auto-apply: the deadline stops the spinner, not the work

When the pipeline succeeds after the deadline, the card upgrades itself and the terminal line
disappears. No tap required.

This is the decision that makes the feature worth building rather than merely correct. The
pocketed-phone case — one of the two the issue is about — is *exactly* the case where the pipeline
finishes fine and finishes late. Under auto-apply that rider unlocks to a finished map card. Under a
tap-required design they unlock to an offer to press a button that will succeed instantly from the
warm cache, which is a worse version of the same outcome.

Suspension works in our favour. The issue records that the belts and the ceiling park together and
fire on resume; the deadline parks with them. So a rider who locks the phone through the whole
window returns to either a finished card or the offer — never to a spinner mid-flight.

The swap goes through the existing `applyOrDeferUpgrade` (`RideSummaryView.swift:190-192`), which
already holds an upgrade back rather than swapping the item out from under a presented share sheet.
Auto-apply promotes that path from rare to routine, which is why D8 makes verifying it mandatory
rather than optional.

Rejected: auto-apply only within a grace window after the deadline. It prices a rare flicker at the
cost of a second timing constant nobody could explain.

## D5 — Terminal state is entered by whichever comes first

The deadline firing, or the provider returning nil. Both produce the same presentation.

A reject at 2 s shows the offer **at 2 s**. It does not sit out the remaining five seconds
pretending to work — which is what a deadline-only design would do, and it would be a new small lie
in place of the old silence. If the deadline fires at 7 s and the pipeline then rejects at 11 s,
nothing changes: already terminal.

The two are presented identically on purpose. The rider's available action is the same either way,
and the tap does the right thing in both cases without needing to know which happened — it joins the
pipeline still running, or starts a fresh one.

## D6 — The copy names no reason

Seven reject categories, nine log lines, and the rider can act on none of them. The action is
identical for all of them. Distinguishing them in the UI costs nine strings and buys the rider
nothing, while making the copy worse in the common case ("the style source failed to load" is not
a sentence for someone standing over a bike).

The reasons keep going to the log, which is where a developer needs them and where
`ShareMapSnapshotter`'s comments say they were put deliberately (`:116-120`).

## D7 — Retry is unbounded, and that is correct

A tap re-enters the same flow with the same `ShareMapRequest`, so the 300 ms show-delay and the
deadline apply again from that moment.

**It cannot stack pipelines.** The request's `cacheKey` is unchanged, so `SharePipelineSlot.run`
joins the in-flight pipeline for that key rather than starting a second one — the one-pipeline
invariant is the slot's whole purpose. Two rapid taps produce two awaiting callers of one pipeline,
which is harmless.

**No retry cap.** There is deliberately no negative cache, so every retry is a genuine fresh
attempt, not a re-read of a stored failure. A cap would be an arbitrary number denying a rider who
has just walked indoors the thing that would now work. The tap is naturally rate-limited by
returning to the hint state while a retry is in flight.

## D8 — The 0.8 s sleep, the prefetch and ownership are untouched

ROH-155's conclusion was that ride end and History want *opposite* policies on when to ask for a
raster, that nothing in the slot, the provider or the view distinguishes them, and that "any change
that treats them alike is wrong in one of them." Three revisions died on it.

This feature sits strictly downstream of that question. The deadline starts when `isUpgrading` flips
to true (`RideSummaryView.swift:173`), which is *after* the 0.8 s sleep and after the
`guard !Task.isCancelled` that turns a History glance into no pipeline at all (`:170-172`). Nothing
here changes when a request is made, who owns it, or what a glance costs. The sleep keeps all three
of its documented jobs.

## D9 — The state machine leaves the app target

All of this currently lives in `RideSummaryView`, and the app target has no unit test target.
`ShareMapSnapshotter` records what that costs, about this exact subsystem
(`ShareMapSnapshotter.swift:122-128`):

> It used to live inline here, where the app target's lack of any unit-test target put it out of
> reach of a test — which is where the review found the ceiling arm clearing the slot out from under
> a live pipeline.

So the decision table moves to **AuraKit** (`Sources/AuraKit/Sharing/`, beside `ShareCardContent`
and `ShareRasterAcceptance`) as a small pure type — a phase enum plus pure transitions over
(elapsed, provider outcome, retry requested), with the deadline injected rather than hard-coded.
Exact naming settles in the plan. The view keeps the gesture, the rendering and the `@State`.

The phases:

- **upgrading** — hint, exactly as today, behind the existing 300 ms show-delay
- **offered** — terminal line; reached by deadline or by nil, whichever came first
- **upgraded** — line gone, map card in place
- **absent** — no route, no stats, or no fallback: no line ever, unchanged from today

## Risks

**A card that changes under a rider who has already decided.** Auto-apply's real cost. `applyOrDeferUpgrade`
covers the presented-sheet case; it does not cover a rider who is simply looking at the card when it
swaps. Accepted, and on the device-pass list.

**The terminal line makes riders wait to share who otherwise would not have.** An offer implies
something better is coming. A rider who would have shared the polyline card at 3 s might now wait.
That is a real behaviour change and it cannot be tested off-device.

**7 s is a guess.** It is short enough to beat the 20 s ceiling and long enough that a healthy
pipeline (4 s style belt plus 6 s render belt in the worst case) usually lands first — which means at
7 s the offer sometimes appears seconds before a success that was already coming, and auto-apply
then swaps it away. Worth watching on device; the constant is injectable so it is cheap to move.

## Out of scope

Any change to when the raster is requested, to the prefetch, or to slot ownership (D8 — that is
ROH-155, closed). The 20 s ceiling itself, which is doing its own job correctly. Blocking or gating
Share. Negative caching. Distinguishing reject reasons in the UI (D6). The already-shared-file
residue: a rider who shares at 1 s shares generation 0, and no later upgrade can change a file
already handed to Messages — ROH-126 accepted that and this spec does not reopen it.

## Testing

The pure phase machine, in `AuraKitTests`:

- Success before the deadline — the offer never appears at all.
- Success after the deadline — offer clears, card swaps.
- Reject before the deadline — offer appears at the reject, **not** at the deadline (D5).
- Deadline fires with the pipeline still live — offer appears, no cancellation.
- Reject arriving after the deadline — no-op, already terminal.
- Retry from offered — back to upgrading, show-delay re-armed.
- Repeated retries — no cap, no stacking.

Device pass, on a real phone, per the repo rule:

- **Swap-while-sheet-open**, now load-bearing rather than a named risk: present the share sheet,
  land an upgrade under it, confirm the sheet neither dismisses nor changes payload.
- **Airplane mode at ride end** → offer appears; re-enable wifi, tap, map arrives.
- **Lock through the entire window** → unlock to a finished card or an immediate offer, never a
  spinner.
- Whether 7 s feels right, and whether the offer flashes before an imminent success.

## Open questions for the device pass

1. Is 7 s the right number, or does the offer appear too eagerly ahead of a landing pipeline?
2. Does the auto-applied swap read as delightful or as a glitch when the rider is looking at it?
3. Does the offer change sharing behaviour — do riders wait for a map they would not have waited for?
