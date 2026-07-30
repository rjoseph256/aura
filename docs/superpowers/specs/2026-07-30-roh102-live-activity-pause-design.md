# Live Activity shifted anchor, stale policy, ContentState migration (ROH-102, Pass 5): design

Slice A, Pass 5 of 6 of the segmented-rides epic (ROH-74). The parent design is
[2026-07-26-segmented-rides-pause-design.md](2026-07-26-segmented-rides-pause-design.md); this
document resolves its D8. Pass 4 (ROH-101) is merged, so the blocker is clear.

**Revision 1.** Two of D8's clauses are corrected below rather than implemented as written. Both
corrections are marked inline and restated under "What D8 got wrong", so a later reader does not
have to diff two documents to find them.

## What Pass 5 is

Pass 4 gave the rider a pause control, a paused cockpit, a paused map ribbon and a paused turn
card. All four are in-app surfaces. The Live Activity is the one paused surface the rider sees
without unlocking the phone, and the only one whose clock the app does not draw: it is
`Text(context.attributes.startedAt, style: .timer)`, rendered by the system, counting wall-clock
from an immutable attribute. Nothing the app pushes can stop it.

So a rider who pauses today gets a cockpit that says PAUSED and a Lock Screen that keeps counting.
The two disagree, and the one that keeps counting is the one visible from across a café table.

Pass 5 is three changes: the clock counts active time instead of wall-clock, it freezes while
paused, and the surface says paused rather than leaving a stopped number to be read as a bug.

## Scope

- `ContentState` carries the active-clock anchor and the frozen paused value; all three widget
  clock call sites move from `context.attributes` to `context.state`.
- A pure clock type in AuraCore, so the anchor arithmetic is tested on the CI host rather than
  eyeballed in a widget preview.
- `RideActivityControlling.update(…)` carries that value; the app conformer and the test double
  move with it.
- The paused Lock Screen and Dynamic Island read as paused, not as frozen.
- Identical-state pushes are dropped, and a paused ride heartbeats slowly instead of pushing the
  same bytes 600 times across a 40-minute stop.

Not in scope: resume from the Lock Screen via an App Intent (D8 defers it, and the scenario it
serves — phone pocketed, rider walking back to the bike — is real, so it stays a named deferral
rather than a silent one). Not in scope: the launch-time sweep of orphaned activities, which is
ROH-124.

## Decisions

### D1: the anchor is `startedAt + pausedSeconds`, carried in `ContentState`

`Text(_, style: .timer)` counts up from its anchor with no per-second pushes, which is why the
elapsed clock is the one value on the Lock Screen that stays honest when the app cannot push. The
anchor being an attribute is what makes it wall-clock; moving it into `ContentState` and shifting
it forward by accumulated paused time makes the same free-running timer display **active** time.

The property is `activeClockAnchor: Date?`. Each resume pushes a later anchor, so the displayed
value steps only at a resume and never runs backwards mid-segment.

`ContentState` is `Codable` and re-serialized on every update, so an activity in flight across an
app update decodes with the key absent. The property is `Optional` for that reason, and every read
site falls back to `context.attributes.startedAt` — which is today's behavior, so the worst case
of a mid-ride app update is a Lock Screen that keeps counting wall-clock until the next push
lands.

### D2: paused-ness is derived from the frozen value, not carried beside it

**Correction to D8**, which specifies that `ContentState` gains `isPaused` *and* the anchor.

`pausedActiveSeconds: Double?` is non-nil exactly while the ride is paused, and holds the active
seconds to display frozen. `isPaused` is a computed `pausedActiveSeconds != nil`.

A separate `isPaused` flag can disagree with the value it describes — paused with no frozen number
to draw, or a frozen number the widget renders as live. Deriving one from the other makes that
state unrepresentable. This is the same trade D1 of the parent spec made when it chose segments
over per-point discontinuity flags, and the same reason: the guarantee should be structural rather
than a convention every call site has to remember.

The cost is that a reader of `ContentState` sees the paused flag one level of indirection away.
A computed property named `isPaused` on the struct pays it off at every call site.

### D3: the clock arithmetic is a pure AuraCore type

```swift
public enum RideActiveClock: Hashable, Sendable {
    case running(anchor: Date)
    case paused(activeSeconds: TimeInterval)
}
```

built by a pure function from the three numbers the recorder already has: the ride's start, the
accumulated paused seconds as of now, and whether a stop is currently open.

Both consumers are places this repo cannot test. A SwiftUI widget body does not run on the macOS
CI host, and neither does ActivityKit. Putting the arithmetic in AuraCore leaves the widget with
nothing but a `switch` over two cases and leaves the controller mapping a value into two
properties, which is the same split that already keeps maneuver-glyph resolution app-side so the
widget stays logic-free (`RideLiveActivityController.swift:89-90`).

AuraCore rather than AuraKit: the widget target depends on both (`project.yml:106-110`), but
`PauseControlCopy` — which renders the frozen value — already lives in AuraCore, and the two
belong together.

`RideActivityControlling.update(…)` gains `activeClock: RideActiveClock`.
`RideSessionCoordinator.pushActivityUpdate()` builds it from `recorder`; `SpyRideActivity` records
it alongside the stats it already records.

### D4: a paused activity says paused

D8 asks only for the timer to freeze. A frozen number on its own is indistinguishable from an
activity that has stopped updating, and it would sit next to `RideStatusPill` still rendering a
mint dot and the word LIVE (`RideActivityComponents.swift:104-109`). The rider would be reading a
surface that contradicts itself.

- `RideStatusPill` gains a paused presentation, taking precedence over stale. A paused ride whose
  app has also died is better described as paused: it is the state the rider acted on, and the
  frozen clock is correct in both cases.
- The free-ride compact-trailing and minimal Dynamic Island glyphs swap `bicycle` for `pause.fill`
  (`RideLiveActivity.swift:40,56`). The minimal presentation is a single glyph, so it is the only
  channel that presentation has.
- The frozen duration renders through `PauseControlCopy.clock(_:)`, so the Lock Screen and the
  cockpit chip agree digit for digit.

Navigate keeps leading with the maneuver. A paused navigate rider still wants to know where the
next turn is, and the turn card treatment is Pass 4's.

Copy for the pill reuses `PauseControlCopy.stateChipLabel` ("PAUSED"), which ships and is tested.

### D5: dedupe the pushes, then heartbeat the pause

**Correction to D8**, which claims the controller's rolling 90 s `staleDate`
(`RideLiveActivityController.swift:31-33`) "would dim the Lock Screen for the remaining 38 minutes
of a 40-minute stop."

That does not follow from the code. `isRecording` stays true across a pause (parent D6), so the
coordinator's 0.5 s ticker keeps running and keeps calling `pushActivityUpdate`
(`RideSessionCoordinator.swift:199-209`). `LocationService` stays in `.navigating` with a live
`CLBackgroundActivitySession` (`LocationService.swift:107-125`), so a backgrounded app keeps its
runtime. The stale date therefore keeps advancing through a pause, and the Lock Screen does not
dim.

The real defect is the opposite one. The controller rebuilds and pushes `ContentState` every
4 seconds whether or not anything changed (`:71-96`), so a 40-minute stop pushes the same bytes
roughly 600 times while the rider is sitting still.

So, two changes that only make sense together:

1. **Drop a push whose `ContentState` equals the last one pushed.** `lastState` is already held
   (`:36`) and `ContentState` is already `Hashable`. This is the change that makes a paused ride
   quiet, and it is correct for a stopped moving ride generally.
2. **Heartbeat while paused: one push a minute, carrying a rolling 5-minute `staleDate`.** The
   heartbeat exists because step 1 removes the traffic that was implicitly keeping the activity
   fresh — without it, D8's described failure would become real for the first time.

The 5-minute stale window keeps `staleDate` meaning what it means today: not "this content is old"
but "the app is no longer alive to push." A paused ride whose app is alive never dims. A paused
ride whose app was killed dims within five minutes, which bounds ROH-124's orphan — an activity
that looks live and un-dimmed for hours — to an activity that looks paused and dimmed. Clearing
`staleDate` outright, D8's other suggestion, is what would create the unbounded case.

The heartbeat is a push of an unchanged state, so it has to bypass the dedupe of step 1 rather
than be defeated by it. It is throttled by the same `lastPush` clock the 4-second cadence uses.

### D6: pause and resume push immediately

The transition bypasses the 4-second throttle, the way a changed turn instruction already does
(`:76-78`). A rider who taps pause and looks at their Lock Screen should not see a running clock
for up to four more seconds — that window is exactly long enough to read as "the tap did not
work."

`RideSessionCoordinator.pause()` and `resume()` call `pushActivityUpdate()` synchronously, in the
same turn as the tap, after the recorder state has moved. Both already do synchronous work in that
turn for the same reason (`RideSessionCoordinator.swift:241`, `:274`).

## Testing

Everything load-bearing here is testable on the macOS CI host, because everything load-bearing was
deliberately put outside the widget:

- `RideActiveClock` construction: running before any pause, running after one pause with the
  anchor shifted by exactly the paused seconds, paused with the frozen value equal to active
  seconds at the moment of the stop, and the anchor never moving backwards across a resume.
- `ContentState.isPaused` derivation, and the decode of a payload written without the two new
  keys — a literal JSON fixture of the old shape, so the migration claim is tested rather than
  asserted.
- Coordinator behavior through `SpyRideActivity`: a pause pushes in the same turn with a paused
  clock, a resume pushes in the same turn with a running clock, and the anchor in the resumed push
  is later than the one in the push before the pause.
- Dedupe and heartbeat: pure policy, so it is a function of (lastState, newState, lastPush, now,
  isPaused) → push or skip, tested directly rather than through a controller that needs
  ActivityKit.

The widget views themselves stay untested by construction, which is why D3 and D5's policy split
exists. What they contain after this pass is a `switch` and a `?:`.

**Device pass.** The issue calls for one, and it is the only way to see the three things a host
test cannot: the OS-side timer actually displaying active time after a resume, the Lock Screen
rendering the paused treatment legibly at arm's length, and an activity started before the change
surviving an app update without a crash or a wall-clock clock. The last one needs a build
installed, a ride started and paused, then the new build installed over it.

## What D8 got wrong

- **The stale-date failure mode was inverted.** D8 described a paused Lock Screen dimming for 38
  minutes. The app keeps background runtime and keeps pushing through a pause, so it does not dim;
  it pushes 600 identical updates instead. D5 fixes the real defect and then adds the heartbeat
  that keeps D8's described failure from becoming real as a side effect of the fix.
- **`isPaused` as a stored field.** D2 derives it instead, so the flag and the value it describes
  cannot disagree.

Neither correction changes the shape of the pass or its blockers.
