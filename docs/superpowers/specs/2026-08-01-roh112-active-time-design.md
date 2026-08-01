# Active time on every post-ride surface (ROH-112) — design

Date: 2026-08-01
Issue: [ROH-112 — Show active time (not moving time) on every surface that reports a ride's duration](https://linear.app/rohun/issue/ROH-112/show-active-time-not-moving-time-on-every-surface-that-reports-a-rides)
Parent spec: `docs/superpowers/specs/2026-07-26-segmented-rides-pause-design.md` (D5)
Status: revision 1.

Slice A of the pause epic is shipped through Pass 6. The recorder accumulates `pausedSeconds`,
schema V6 persists it, the cockpit shows a paused state, and the Live Activity honors it. No
post-ride surface reads any of it.

## Problem

Parent D5 decided that a finished ride leads with **active** time, `elapsed - paused`, because that is
the number the rider was watching on the HUD when they pressed End. Moving time appears on no
live screen, so leading with it shows the rider a number they never saw.

None of that was built. Every surface that reports a finished ride's duration still reports
`RideStats.movingTimeSeconds`:

| Surface | Site |
| -- | -- |
| Ride summary | `RideSummaryView.swift:279` |
| Share card | `ShareCardContent.swift:38`, rendered at `ShareCardView.swift:163` and `:207` |
| History row caption | `HistoryView.swift:171` |
| Home last-ride card | `LastRideCard.swift:104` |
| Widget last-ride card | `LastRideWidget.swift:72`, `:103`, `:166` |

Two of those are not in the issue's own list. The ride summary is the surface that decision was
actually about, and ROH-101 deferred it here (`2026-07-29-roh101-pause-control-design.md:404`).
The Home last-ride card was missed entirely, and it sits one tap above a History row that would
otherwise report the same ride differently.

The rider-visible consequence today: pause for a twenty-minute coffee and nothing anywhere
records that you were out for longer than you were pedaling. The paused time is stored and
never shown.

## Decisions

Numbered D1 onward for this spec. Every reference to the pause epic's own numbering is written
as "parent D5" and so on.

### D1 — One pure type computes both numbers

`RideDuration` in `AuraCore/Sources/AuraCore/Ride/RideDuration.swift`, beside `RideActiveClock`:

```swift
public struct RideDuration: Equatable, Sendable {
    public let elapsedSeconds: TimeInterval
    public let activeSeconds: TimeInterval
    public init?(startedAt: Date, endedAt: Date?, checkpointedAt: Date?, pausedSeconds: Double)
}
```

with `Ride.duration` and `RideSummary.duration` as the two call-site conveniences. It is the
finished-ride counterpart of `RideActiveClock`, which does the same subtraction while the ride is
running, and its doc comment says so. The two definitions of "active" must never drift, because
the whole point of parent D5 is that the rider sees the same clock after the ride that they saw
during it.

The initializer is failable. `nil` means the ride has no usable end at all, which is the only
case any surface renders as unavailable.

Rules, each pinned by a test:

* End is `endedAt ?? checkpointedAt`. `nil` when both are nil.
* `elapsedSeconds = max(0, end - startedAt)`, so a backward device-clock step reads zero rather
  than a negative clock.
* Paused is clamped into `0...elapsedSeconds` before subtracting, so `activeSeconds` can never be
  negative and never exceed elapsed, whatever a corrupt or future-dated `pausedSeconds` says.
* A ride recorded before pause existed has `pausedSeconds == 0`, so active equals elapsed. That is
  truthful: no pauses were recorded.

### D2 — Unfinished rides fall back to the checkpoint

An unfinished ride has no `endedAt`, so parent D5's literal reading ("elapsed and active are
unavailable") would blank the duration on a recovered ride that can honestly report one.
`checkpointedAt` is when recording stopped, which is the most the app knows, and the row already
carries the unfinished badge (ROH-107) telling the rider the ride was cut short. Using it costs
nothing and reads better than a dash.

Rows with neither timestamp are the legacy PR #90 dev-build rows, which wrote a nil `endedAt` and
no marker. Those are the only rows that render unavailable.

### D3 — Constrained surfaces show active alone; only the summary shows the pair

Parent D5 says the same pair is used everywhere a ride's duration is shown. Its goal is that one ride
cannot report three different durations, and showing one consistently-defined number achieves
that. Printing two clocks in a History caption or a 92 pt widget stat cell does not fit, and
would cost the widget its climb cell.

So: the summary shows active with elapsed beneath it. The share card, both last-ride cards, and
the History caption each show active alone. Moving time survives on the ride summary only.

### D4 — The summary keeps its moving cell, and the layout is active, moving, top speed

Elapsed is a caption under the active value, not a fourth peer cell:

```
38 min          31 min        24.3
active          moving        mph top
48 min elapsed
```

Three cells keep the existing `ViewThatFits` reflow (`RideSummaryView.swift:266`) working on an
iPhone SE, and a subordinate caption reads as "secondary" more literally than an equal-weight
cell would.

Keeping moving time is not only a product call. `RideTestID.summaryMoving` is what ROH-103's
paused golden ride reads to tell a segmented save from a flattened one, since a flattened ride
reads about 14 minutes against about 4 for a segmented one. Active time is computed from
timestamps and is identical either way, so deleting that cell would leave the E2E's segmentation
proof with nothing to read. **The moving cell keeps its identifier, its label, and its exact value
expression.**

### D5 — Unavailable durations are omitted from captions and dashed in stat cells

A caption is a sentence of terms joined by `·`, so a missing duration drops its term:
"Explore · ↑ 300 ft". A stat cell is a fixed slot in a grid and cannot be dropped, so it shows
`—`, which is what those cells already show for a statless ride.

The existing statless guards run first and are untouched. A ride saved without computed stats
still renders `—` for its whole stat block on the widget (`LastRideWidget.swift:72`) and its whole
line on the Home card (`LastRideCard.swift:103`), even though its duration is computable from
timestamps alone. Showing a lone duration beside dashes for distance and climb would be a new
treatment, and this issue is not the place to invent one.

### D6 — The widget falls back to moving time under its own label

`WidgetSnapshot.LastRide.activeSeconds` returns nil when `pausedSeconds == nil`. That optional is
the existing provenance guard: a writer that knew about `endedAt` also wrote `pausedSeconds`, so
its absence means the payload predates the keys rather than meaning the ride never paused
(`WidgetSnapshot.swift:151-168`). The guard is reused rather than duplicated, and the shape change
that ROH-112 was expected to make to that pair, turning `pausedSeconds` into a non-optional
defaulting to zero, is exactly what the comment there warns kills the guard silently. It stays
optional.

In that window the widget shows the moving number under a `MOVING` label. It never prints a
moving-time number under an `ACTIVE` label, which would be the same defect this issue exists to
close. When the app next foregrounds, `WidgetRefresh` rewrites the snapshot and the cell changes
to `ACTIVE`.

**No snapshot version bump.** The keys are already optional inside version 1. Bumping would make a
new widget binary reject every payload an old app wrote, which is the failure the optionals were
added to prevent.

### D7 — Views project pure content; captions are assembled in tested code

Two new pure types in `AuraKit/Formatting`, following `ShareCardContent` and
`ExploreInstrumentState`:

* `RideSummaryStats(ride:units:)` resolves the three summary cells to display strings plus the
  active cell's spoken label, so the stat row becomes a dumb projection.
* `RideCaptionText` assembles the History caption and the Home card's stats line through one
  shared "join the non-empty terms with `·`" helper, so a dropped duration term cannot leave a
  doubled separator behind on either surface.

`ShareCardContent.movingTime` is **renamed** to `activeTime`, typed `String?`, rather than joined
by a new sibling property. Leaving the old property in place is how a caller keeps rendering the
old number. Its `nil` drops the time term from the card's stat run, per D5 above.

Every rendered duration goes through `RideStatsFormatter.minutes`, so active, elapsed, and moving
share one rounding path and a rider cannot see two of them disagree by a rounding step.

The active cell sets an explicit accessibility label, "Active time, 38 min. Elapsed, 48 min.",
rather than relying on `children: .combine` to order a value, a label, and a caption.

## Testing

Package tests, which run on the macOS CI host:

* `RideDurationTests`: the checkpoint fallback, nil when there is no end at all, both clamps, and
  a pre-pause ride where active equals elapsed.
* `RideSummaryStats` and `RideCaptionText`: the rendered strings for a paused ride, an unpaused
  ride, and a ride with no computable duration, including the separator behavior.
* `ShareCardContent.activeTime`, present and nil.
* A `WidgetSnapshot.LastRide` decoded from JSON without the ROH-107 keys reports
  `activeSeconds == nil`; one decoded from a current payload does not.
* One end-to-end package test through the recorder: record, pause, resume, end, save, read the
  summary back, and assert the displayed active string is below the displayed elapsed string by
  the pause. This is where a regression that quietly hands elapsed to both dies.

XCUITest, added to ROH-103's existing paused golden ride:

* The `summary.active` cell exists and its label carries both terms.

**What that E2E does not prove.** The paused dwell is wall-clock: the fixture's 600 s stop replays
in about 30 s at 20x, and the recorder measures the tester's actual dwell, not the fixture's
stamps. Whole-minute formatting cannot resolve a 30 s gap, so the assertion covers presence and
wiring only. The subtraction itself is proven by the package test above, and this is stated here
because ROH-103's review found two assertions whose coverage claims had drifted from what they
checked.

The moving-time band assertion (`RideE2EUITests.swift:340`) is unchanged and keeps proving
segmentation.

## Risks

* Renaming `ShareCardContent.movingTime` is a compile break at every call site, which is the point.
* Moving three cells behind `RideSummaryStats` touches the cell ROH-103 reads. The moving cell's
  identifier, label, and value expression are held byte-identical, and the E2E is the check.
* The widget has three call sites for the same stat (medium, rectangular, and the accessibility
  label). They resolve one private computed pair so the fallback cannot apply to two of the three.
* A History row for a ride still recording on another device now shows active time up to its last
  checkpoint. Correct, and the unfinished badge already says the row is not final.

## Out of scope

Weekly aggregates (`RideAggregator.movingTimeSeconds` and the goal ring) stay on moving time; they
are sums across rides, not one ride's duration. The live HUD, the Live Activity, and the paused
chip already run on active time. `RideStatsFormatter.minutes` keeps its whole-minute output, so a
two-hour ride still reads "125 min" on every surface it does today; changing it is a formatter
change with its own callers and its own review.
