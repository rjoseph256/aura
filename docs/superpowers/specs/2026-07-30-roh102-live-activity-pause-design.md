# Live Activity shifted anchor, stale policy, ContentState migration (ROH-102, Pass 5): design

Slice A, Pass 5 of 6 of the segmented-rides epic (ROH-74). The parent design is
[2026-07-26-segmented-rides-pause-design.md](2026-07-26-segmented-rides-pause-design.md); this
document resolves its D8. Pass 4 (ROH-101) is merged, so the blocker is clear.

**Revision 2.** Three independent reviewers refuted revision 1. Nine of their findings changed a
decision rather than a sentence, and two were fatal: revision 1's dedupe could never have fired
during a pause, and its "immediate" pause push would have been swallowed by the throttle it
claimed to bypass. Both are recorded under "What revision 1 got wrong" rather than quietly
deleted. Revision 1 also asserted the parent D8 was factually wrong; revision 2 withdraws that
claim as unproven in both directions and designs so the answer does not matter.

## What Pass 5 is

Pass 4 gave the rider a pause control, a paused cockpit, a paused map ribbon and a paused turn
card. All four are in-app. The Live Activity is the one paused surface the rider sees without
unlocking the phone, and the only one whose clock the app does not draw: it is
`Text(context.attributes.startedAt, style: .timer)`, rendered by the system, counting wall-clock
from an immutable attribute. Nothing the app pushes can stop it.

So a rider who pauses today gets a cockpit that says PAUSED and a Lock Screen that keeps counting.
The two disagree, and the one that keeps counting is the one visible from across a café table.

## Scope

- The clock on all five widget call sites reports **active** time, from `context.state`.
- While paused, the clock reports **how long this stop has been**, and keeps moving.
- One `Codable` payload type in AuraCore, so the push policy and its equality are host-tested.
- The paused Live Activity reads as paused on both modes and every presentation, and says so to
  VoiceOver.
- A killed ride stops claiming to be paused.
- Identical-state pushes are dropped; a liveness heartbeat replaces what they were implicitly
  proving.

Not in scope: resume from the Lock Screen via an App Intent (D8 defers it — see D9 for the real
cost of that deferral, which is larger than D8 stated). Not in scope: the launch-time sweep of
orphaned activities, which is ROH-124; D6 closes the failure it would otherwise cause here.

## Decisions

### D1: the clock is a two-case value, and the paused case counts up

```swift
public enum RideActiveClock: Codable, Hashable, Sendable {
    /// Active time is `now - anchor`, where `anchor = startedAt + pausedSeconds`.
    case running(anchor: Date)
    /// `since` is the instant the stop began; `activeSeconds` is the ride's active time,
    /// frozen at that instant.
    case paused(since: Date, activeSeconds: TimeInterval)
}
```

**Running.** `Text(anchor, style: .timer)` counts up from the anchor with no per-second pushes,
which is why the elapsed clock is the one value on the Lock Screen that stays honest when the app
cannot push. Shifting the anchor forward by accumulated paused time makes that same free-running
timer display active time. Each resume pushes a later anchor, so the value steps only at a resume.

**The anchor is clamped to `now`.** `refreshElapsed` clamps its in-app equivalent for a reason
(`RideSessionCoordinator.swift:222`), and `RideRecorder` records the residual weakness as ROH-130.
A backward wall-clock step (an NTP correction mid-ride) can make `startedAt + pausedSeconds`
exceed `now`, and `Text(_, style: .timer)` with an anchor in the future counts **down** — a
strictly worse failure on the Lock Screen than the clamped in-app number.

**Paused counts up from the stop, not frozen at the ride's active time.** Revision 1 froze and
displayed active ride time. That answers a question the stopped rider is not asking. The most
predictable failure of a manual pause is a forgotten resume, which is why Pass 4 built a five-rung
nudge ladder around it; the number that rider needs is *how long have I been stopped*, and
`PAUSED 40:23` meaning active ride time tells them nothing about whether they stopped 40 seconds
or 40 minutes ago.

`Text(since, style: .timer)` answers the right question, and three properties fall out of it:

- It costs zero pushes and keeps rendering when the app is suspended or dead, because the system
  draws it.
- It is **visibly moving**, which dissolves the "a frozen number reads as a broken activity"
  problem that revision 1 had to invent a pill to explain.
- It is the same quantity the cockpit chip shows (`PauseControl.swift:21-22`), so the two surfaces
  now answer alike. They may still differ in leading-zero shape, because one is system-formatted
  and the other is `PauseControlCopy.clock`; D10 checks that on device. Revision 1's claim that
  they "agree digit for digit" was false in both quantity and format.

`activeSeconds` rides along frozen because ending a ride while paused needs it, and because a
resume must not have to recompute it. It is not rendered while paused.

**Neither case carries a value that moves while paused.** This is load-bearing, not incidental —
see D3.

### D2: one optional payload field, and one payload type in AuraCore

`ContentState` gains exactly one property: `clock: RideActiveClock?`.

`ContentState` is `Codable` and re-serialized on every update, so an activity in flight across an
app update decodes with the key absent. `Optional` handles that: Swift's synthesized `init(from:)`
uses `decodeIfPresent` for `Optional` stored properties, so a missing key yields `nil` rather than
throwing. Every read site falls back to `context.attributes.startedAt`.

**One field, not two.** Revision 1 specified `activeClockAnchor: Date?` alongside
`pausedActiveSeconds: Double?` and argued that deriving `isPaused` from the second made
contradiction unrepresentable. It did the opposite: two independent optionals are a product with
four inhabitants, one of which — both non-nil — has no defined rendering, and the invariant was
enforced only by the mapping site. A single optional carrying a two-case enum has three states,
all meaningful: absent (legacy), running, paused.

**The payload mirror.** `RideActivityPayload` in AuraCore holds every live value —
the six that `ContentState` holds today plus `clock` — as a pure `Codable, Hashable, Sendable`
value. The controller keeps `lastPayload` rather than `lastState`, and derives `ContentState` from
a payload on every push.

This exists because of a testability boundary, not for elegance. `ContentState` is declared inside
a type conforming to `ActivityAttributes`, in an app-target file that imports ActivityKit
(`RideActivityAttributes.swift:1,22`), shared into the widget by source membership
(`Aura/project.yml:96`). The SwiftPM test targets cannot see it, `AuraKit` deliberately never
imports ActivityKit (`RideSessionSeams.swift:12-13`), and `Aura/project.yml` declares no app unit
test bundle — only `Aura`, `AuraWidgets` and `AuraUITests`. So anything expressed in terms of
`ContentState` is untestable on any platform this repo runs tests on. Revision 1 promised a
migration fixture test and a push policy keyed on `ContentState`; neither could have been written.

With the payload in AuraCore, the equality that drives the dedupe is host-tested, and
`ContentState` is a projection with no logic in it.

`ContentState`'s doc comment gains the rule this establishes: **every field added to `ContentState`
from now on is `Optional` or defaulted**, because an activity archived by an older binary will be
decoded by a newer one. That belongs in the type, not only in a spec that gets archived.

### D3: the anchor must not move while paused, or the dedupe cannot work

`RideRecorder.pausedSeconds(asOf:)` **grows every tick while a stop is open** — deliberately, so
the in-app active clock stops rather than the paused total lagging
(`RideRecorder.swift:126-129`). So an anchor computed as `startedAt + pausedSeconds(asOf: now)`
is a different `Date` on every 0.5 s tick of a pause, even though the active time it encodes is
constant.

`ContentState` is `Hashable` over its stored properties. A per-tick-distinct anchor is a
per-tick-distinct state, so a dedupe keyed on state equality would **never fire during a pause** —
the one scenario it exists for. A reviewer measured revision 1's shape at 200 simulated paused
ticks: 200 distinct anchors, one distinct active time.

D1's `.paused` case carries no anchor at all, which makes the trap unrepresentable rather than a
rule someone has to remember. `since` and `activeSeconds` are both fixed at the instant of the
stop.

This requires one addition to `RideRecorder`: the pause instant is currently private
(`pauseStartedAt`), and D1's `.paused(since:)` needs it. It is exposed as a read-only
`pausedSince: Date?`, non-nil exactly while a stop is open — the same predicate `isPaused`
already reports.

### D4: the push policy is pure, lives in AuraCore, and owns the whole decision

```swift
public enum RideActivityPushDecision: Hashable, Sendable {
    case push(staleDate: Date)
    case skip
}

public enum RideActivityPushPolicy {
    public static func decide(last: RideActivityPayload?,
                              next: RideActivityPayload,
                              lastPushedAt: Date?,
                              now: Date) -> RideActivityPushDecision
}
```

Rules, in order:

1. No previous payload, or the turn instruction changed → push. (The turn bypass ships today,
   `RideLiveActivityController.swift:76-78`.)
2. **The paused-ness changed → push.** This is what makes a pause reach the Lock Screen in the
   same turn as the tap. Revision 1 said the transition "bypasses the 4-second throttle" and then
   specified only that the coordinator call `pushActivityUpdate()` synchronously — which bypasses
   nothing, because the throttle lives in the controller on the far side of the seam. A tap
   landing in the throttled window, which most taps do, would have returned early and changed
   nothing.
3. `now - lastPushedAt >= 60` → push. **The heartbeat, and it is not gated on paused.** Gating it
   on paused, as revision 1 did, would falsely dim a healthy ride: `record()` is the only writer
   of the stats (`RideRecorder.swift:81-91`) and `GPSFix.isAcceptable` rejects unusable fixes
   (`LocationService.swift:77`), so a garage start, a tunnel or a bad urban canyon produces
   byte-identical state for minutes. Today's unconditional 4 s cadence hides that; a dedupe
   without an unconditional heartbeat would dim a ride that is recording perfectly.
4. The payload changed and `now - lastPushedAt >= 4` → push. (Today's coalescing cadence.)
5. Otherwise skip.

`staleDate` is `now + 90` in every case — unchanged from today's `staleInterval`. Revision 1
invented a 5-minute paused window; with a 60 s heartbeat the existing 90 s window already never
expires while the app is alive, in either state, so the wider window bought nothing and cost three
and a half minutes of false liveness on a dead ride. **This is what makes the policy correct
whether or not the app keeps background runtime through a long pause** (see D8): alive, the
heartbeat keeps it fresh; suspended or killed, it goes stale within 90 s and D6 makes that
legible. Both outcomes are honest.

**A skip must not advance anything.** `lastPayload` and `lastPushedAt` move only on `.push`, so
the throttle clock measures time since the last *emitted* push. The current code assigns
`lastPush = now` at `:80`, before the state is even built at `:83-90`, so the minimal-diff
implementation of a dedupe would leave that assignment above the new guard — and then every
skipped push would advance the clock, `now - lastPushedAt` would never reach 60, and the heartbeat
would be dead code. That is the second fatal defect in revision 1, and it is structural here: the
decision type has no "skip but advance" case, and the controller has exactly one assignment site,
inside the `.push` branch.

### D5: pushes are serialized, and `lastPayload` means "what the widget has"

`lastState` is assigned before the push today and independent of it, and the push is an
unstructured `Task { await activity.update(content) }` with no ordering guarantee between
successive tasks (`RideLiveActivityController.swift:91-95`). That is harmless while every tick
pushes unconditionally. Under D4 it is not: `lastPayload` becomes the gate, so if a ticker push
and the pause push are two racing tasks and the ticker's completes second, the widget ends up
holding the **running** state while `lastPayload` says paused — and the dedupe then suppresses
every push until the heartbeat 60 s later. A running clock on the Lock Screen for a minute after
the rider paused is worse than the 4-second window D4's rule 2 exists to close.

So the controller drains pushes through a single chained task, and assigns `lastPayload` /
`lastPushedAt` **after** `await activity.update` returns. Ordering is then guaranteed and the
dedupe state describes what the widget actually has rather than what the app intended to send.

No new timer. The heartbeat rides the coordinator's existing 0.5 s ticker
(`RideSessionCoordinator.swift:199-209`), which `stopStreaming()` already cancels
(`:402-403`) and which therefore cannot outlive the ride. A controller-owned timer would need
teardown at four sites — `end()`, `cancel()`, a thrown `Activity.request`, and the
`areActivitiesEnabled == false` early return — against zero here.

One related ordering fix in the same file, because this pass is editing it: `start()` returns on
`!areActivitiesEnabled` (`:47`) **before** the defensive `end()` at `:49`, so a rider who disables
Live Activities mid-ride leaves the running one never ended and never updated again. The guard
moves below the defensive end.

### D6: stale beats paused in the word

A jetsam kill during a pause is likely by construction — backgrounded, no interaction, wake lock
released (`RideSessionCoordinator.swift:250`), for tens of minutes — and nothing ends the orphan,
because `end()` guards on an `activity` the fresh process does not have and no code reads
`Activity<RideActivityAttributes>.activities` anywhere in the repo. That is ROH-124.

Revision 1 made the paused pill take precedence over stale. That deletes the only word on the
surface carrying the truth (`RideActivityComponents.swift:98-102`), leaving a killed ride wearing
a confident PAUSED with a plausible, still-moving clock. The rider glances at the Lock Screen,
reads "still paused, good", rides home for an hour, and records none of it. Revision 1's own
argument for it — "a paused ride whose app has died is better described as paused: it is the state
the rider acted on" — is wrong, because paused implies resumable and Pass 4 established that a
persisted checkpoint never is.

**So the two compose.** `RideStatusPill` renders paused and stale together: `PAUSED` while fresh,
`PAUSED · NOT UPDATING` when also stale. The orphan self-labels within 90 s, which is what bounds
ROH-124 here — not the stale window revision 1 leaned on, which its own pill change had removed.

The word does the work because the alternative signal cannot. `statOpacity` (`RideLockScreenView.swift:24`)
is a 0.4 alpha on three numerals that a paused rider already expects to be frozen. Dimming is not
a word.

### D7: the paused treatment covers both modes and every presentation

Revision 1 named two Dynamic Island lines and left the rest, including the surface the pass exists
for. The five clock call sites are:

| Site | Presentation |
| -- | -- |
| `RideLiveActivity.swift:49` | compact trailing, free ride |
| `RideLiveActivity.swift:94` | expanded trailing, free ride |
| `RideLiveActivity.swift:121` | expanded bottom, navigate (via `RideTimerStatCell`) |
| `RideLockScreenView.swift:45` | Lock Screen, free ride |
| `RideLockScreenView.swift:87` | Lock Screen, navigate |

The parent D8 counted three by counting the shared component once instead of its call sites, and
revision 1 copied that. The two it missed are both on the Lock Screen — every device shows it, and
Dynamic Island is supplementary. Implemented as written, the Island would have shown active time
while the Lock Screen kept counting wall-clock.

`RideTimerStatCell` carries three of the five and its whole API is `let start: Date`. It takes the
`RideActiveClock` instead and switches on it.

Beyond the clock:

- **The identity glyph swaps to `pause.fill` in both modes** — Lock Screen header
  (`RideLockScreenView.swift:42`), compact leading, minimal, and expanded leading
  (`RideLiveActivity.swift:40,56,67`). Note that `:40` is compact **leading**; revision 1 called it
  compact trailing, which for free ride is the timer. Minimal is a single glyph, so it is that
  presentation's only channel, and navigate must swap too or a paused navigate ride is
  indistinguishable from a running one on every Dynamic Island phone.
- **The clock's label stops saying `TIME` / `ELAPSED`** while paused (`:100`, and the
  `RideTimerStatCell` label at each call site). It says `PAUSED`. The expanded Dynamic Island has
  no `RideStatusPill` at all, so the label is the only paused signal that presentation gets.
- **The clock's mint tint goes to secondary while paused.** `RideTimerStatCell`'s own doc comment
  says mint "marks it as the live, trustworthy value" (`RideActivityComponents.swift:45`).
- **The imminent-turn treatment is suppressed while paused.** `rideActivityIsImminent` fires under
  150 m (`RideActivityComponents.swift:16-19`), and pausing within 150 m of a turn — at the
  junction, at the light, at the shop before the turn — would otherwise leave the glyph inverted to
  a solid mint fill with the distance in mint (`RideLockScreenView.swift:64-76`), the app's single
  most urgent cue, on a ride recording nothing.
- **Speed keeps rendering `0.0` while paused.** `RideRecorder.pause` zeroes it deliberately
  (`:102`). Zero is what a stopped bike is doing; `–` would read as missing data, which is a
  different and false claim.
- **Navigate's turn distance is held while paused.** `GuidanceViewModel.applyProgress` updates
  `lastUpdate` before its `isPaused` guard (`GuidanceViewModel.swift:142-149`), so a stationary
  rider's distance-to-maneuver still moves with GPS jitter. Left alone it would tick beside a
  frozen clock and a PAUSED pill — two adjacent numbers disagreeing about whether the ride is
  moving — and it would also defeat the dedupe on every navigate pause. The payload holds the last
  pre-pause value while paused.

### D8: the background-runtime premise is unproven, and the design no longer rests on it

The parent D8 asserts a 90 s stale date "would dim the Lock Screen for the remaining 38 minutes of
a 40-minute stop." Revision 1 asserted the opposite: that `isRecording` stays true through a pause
(true — `RideRecorder.swift:23`, and the ticker's guard is `isRecording`, not `!isPaused`), so the
ticker keeps pushing and the stale date keeps advancing.

The step neither document supports is the one that matters: whether a backgrounded, screen-released
app holding a `CLBackgroundActivitySession` (`LocationService.swift:124`) keeps executing
`Task.sleep` loops for forty minutes against a stationary device. Revision 1 cited `setMode`'s
`pausesLocationUpdatesAutomatically` as evidence, which is close to inert — the ride stream is
`CLLocationUpdate.liveUpdates()` (`:131`), and this repo established during ROH-99 that
`liveUpdates` reads nothing from `CLLocationManager`. A stationary device for forty minutes is
exactly the condition location delivery backs off under.

Revision 1's asymmetry made this dangerous: its heartbeat had no tick source other than that same
ticker, so if the premise were false the correction would fail in precisely the way it accused D8
of failing.

**Revision 2 withdraws the claim.** D4's uniform 90 s stale window is correct either way: alive,
the 60 s heartbeat keeps the activity fresh in both states and it never dims; suspended or killed,
it dims within 90 s and D6 spells out why. No constant in this design is chosen from the unproven
premise. D10 measures it anyway, because the answer is worth knowing for Slice B's auto-pause,
which will pause far more often.

### D9: what the deferral of Lock Screen resume actually costs

D8 defers resume-from-Lock-Screen and justifies it against one scenario, "phone pocketed, rider
walking back to the bike." That understates it. `pause()` releases the wake lock
(`RideSessionCoordinator.swift:250`), so on any stop longer than auto-lock the phone **will** be
locked — the locked screen is the default state at the moment of resume, not an edge case. Every
resume then costs a wake, a Face ID attempt through a helmet and sunglasses or a passcode through
wet gloves, a tap into the app, and a hunt for the control, while the ride records nothing.

This pass does not change that, and the sequencing is still defensible: an App Intent is its own
surface with its own failure modes and it wants the runtime question in D8 answered first. But the
cost is recorded honestly here — Pass 5 builds the surface that reports the problem and leaves it
inert at the moment the rider wants to fix it — so that whoever schedules the App Intent is
choosing against a real number.

### D10: testing

**Host-tested in AuraCore**, which is the point of D2's payload extraction:

- `RideActiveClock` construction: running before any pause; running after one pause with the
  anchor shifted by exactly the paused seconds; the clamp holding under a backward wall-clock step
  so no anchor is ever in the future; paused carrying the stop instant and the frozen active
  seconds; the anchor never moving backwards across a resume; and — against D3's trap — the paused
  case being **equal across a span of ticks**.
- `RideActivityPayload` `Codable` round-trip, and a decode of a payload written without the clock
  key, so the migration fallback is exercised on a real decoder.
- `RideActivityPushPolicy.decide` as a decision table: the first push, the turn bypass, the
  paused-ness transition bypass, the 4 s coalescing, the 60 s heartbeat firing on an unchanged
  payload in **both** states, and a skip leaving the caller nothing to advance.
- Coordinator behavior through `SpyRideActivity`: pause and resume each push in the same turn with
  the right clock case, the resumed anchor later than the pre-pause one, and the pause push
  ordered **before** the checkpoint flush.

**Not testable, and named rather than pretended:** `ContentState` itself — its `Optional` decode
and its projection from the payload — because no test target on any platform can see the type
(D2). The residual risk is one 1:1 mapping and a language rule; D2 shrinks it as far as this
repo's target layout allows, and D10's device pass covers the rest. Revision 1 claimed this was
the thing it would prove rather than assert, which was backwards.

**Device pass**, on a real phone:

1. Ride, pause, resume, and confirm the OS-side clock reports active time after the resume — not
   wall-clock, not a value that jumped.
2. The paused Lock Screen and both Dynamic Island presentations, in free ride and navigate, read
   as paused at arm's length. Including a pause taken within 150 m of a turn, which is where the
   imminent-cue suppression is visible.
3. Leading-zero shape of the paused counting-up timer against the cockpit chip (D1).
4. VoiceOver on the paused Lock Screen announces paused rather than "in progress".
5. **The runtime measurement (D8):** a forty-minute backgrounded pause with a log line per emitted
   push, to establish whether the ticker survives. This is the one that settles the parent D8 and
   informs Slice B.
6. An activity started on the old build, then the new build installed over it. **Expected outcome:
   a permanently wall-clock activity**, not a recovered one — the process is gone, no ride is in
   progress in the new process, and orphan recovery is ROH-124. Revision 1 wrote this step
   expecting recovery, which would have read a correct result as a failure.

## An inconsistency this pass leaves standing

After Pass 5, "how long was my ride" has four answers: active time on the Lock Screen and the
cockpit, **moving time** on the summary, History and the share card
(`RideSummaryView.swift:214`), and **wall-clock** in Apple Health, which receives no pause events
(`WorkoutData.swift:27-35`). The rider's last glance before ending says one number and the summary
one tap later says a smaller one, at the moment of maximum attention.

That is ROH-112, it is open, and Pass 5 deliberately does not widen its scope to cover it. Naming
it here so the divergence is a known debt rather than a surprise found in the summary screen.

## Invariants this design depends on

Each is enforced structurally, not by a comment:

1. Neither `RideActiveClock` case carries a value that moves while paused. (D3 — the trap that
   killed revision 1's dedupe.)
2. The running anchor is never in the future. (D1 — a future anchor counts down.)
3. A skip advances nothing; `lastPayload` and `lastPushedAt` move only inside the `.push` branch.
   (D4.)
4. `lastPayload` is assigned only after the push it describes has returned. (D5.)
5. `ContentState` is derived solely from `RideActivityPayload`, so payload equality implies content
   equality. (D2.)
6. Every future `ContentState` field is `Optional` or defaulted. (D2 — recorded in the type's doc
   comment.)
7. The pause push precedes `flushCheckpoint` in `pause()`, which its own doc calls "the expensive
   part … a full-track encode and a mirrored write, in this same turn"
   (`RideSessionCoordinator.swift:231-232`), at the exact instant a jetsam kill is most likely.

## What revision 1 got wrong

- **The dedupe could never have fired during a pause.** Its anchor moved every tick, so every
  paused push was a distinct state. The scenario it was designed for was the one scenario it
  could not serve. (D3.)
- **The immediate pause push was not immediate.** Calling the coordinator's push synchronously
  does not bypass a throttle that lives in the controller. Most taps would have changed nothing —
  and the coordinator test revision 1 prescribed would have passed anyway, because the spy
  replaces the controller the throttle lives in. (D4 rule 2, D10.)
- **A dedupe skip would have advanced the throttle clock**, killing the heartbeat and delivering
  the dimming it was justified as preventing. (D4.)
- **The heartbeat was gated on paused**, which would have falsely dimmed a healthy ride with no
  acceptable GPS fixes. (D4 rule 3.)
- **It froze the wrong number.** Active ride time, not the stop duration the forgotten-resume
  rider needs — and freezing it created the "reads as broken" problem that a counting-up timer
  does not have. (D1.)
- **Paused outranked stale**, leaving a killed ride wearing a confident PAUSED. (D6.)
- **It counted three clock call sites**, missing both Lock Screen ones. (D7.)
- **It promised a migration test that cannot be written** and a policy whose signature named a
  type AuraCore cannot see. (D2, D10.)
- **It asserted the parent D8 was wrong** on a premise it had not measured, while depending on
  that same premise for its own fix. (D8.)
- **It claimed the Lock Screen and cockpit clocks "agree digit for digit."** Different quantities,
  different formatters. (D1.)

Two of these were fatal on their own. Both came from the spec text rather than from anything an
implementer would have done wrong, which is the case for the gate.
