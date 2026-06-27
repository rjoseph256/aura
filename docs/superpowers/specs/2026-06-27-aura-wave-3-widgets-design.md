# Aura Wave 3 — Home and Lock Screen widgets: design

**Goal:** Add two Home Screen / Lock Screen widgets to the existing `AuraWidgets`
extension: a **Last ride** widget and a **Weekly goal** widget. The widget reads
a small denormalized snapshot the app writes into a shared App Group container,
so the extension never touches SwiftData, the migration plan, or Mapbox. The data
preparation and goal/format logic is pure and unit-tested in `AuraCore`/`AuraKit`;
the WidgetKit `TimelineProvider` and SwiftUI views live in `AuraWidgets`. The
widgets honor the mono-lime `AuraTheme` — no new palette.

**Status:** approved design (built autonomously), ready to plan.

## Context

Wave 3 is three near-term features in build order: HealthKit, then turn haptics,
then home and lock-screen widgets. HealthKit shipped as PR #12 (main `7faadac`)
and haptics as PR #13 (main `0cb3706`). This is the third and last item; shipping
it completes Wave 3.

The architecture has three compiled layers plus the widget extension:

- `AuraCore`: pure Swift models and protocols, no UIKit/SwiftUI/Mapbox/WidgetKit.
  Builds on the macOS CI host.
- `AuraKit`: depends on `AuraCore`, may import CoreLocation, imports no SwiftUI
  and no WidgetKit. Holds the observable stores (`RideStore`, `SettingsStore`),
  the read-path projection (`RideSummary`, `RideAggregator`), and the pure
  plotting helpers. Also builds on macOS, so any iOS-only API here must be
  `#if os(iOS)` guarded.
- `Aura`: the app target. SwiftUI plus the Mapbox-backed implementations. It owns
  the writes into the shared container and the `WidgetCenter` reloads.
- `AuraWidgets`: the WidgetKit extension. Today it hosts only the Live Activity;
  this work adds the two timeline widgets beside it.

This sub-project reuses two patterns the Live Activity established (see
`Aura/project.yml` and `Aura/Widgets/`):

1. **Sharing types and theme into the extension by target membership.** The
   `AuraWidgets` target lists specific files by path — `RideActivityAttributes.swift`,
   `AuraTheme.swift`, `StatPair.swift`, `SpeedReadout.swift` — plus its own
   `Widgets/` directory, and depends on `AuraCore`/`AuraKit` only (no Mapbox).
   The new widgets extend that list with `RouteThumbnail.swift`.
2. **Keeping framework-coupled code out of the SwiftPM package.** ActivityKit and
   WidgetKit are unavailable on the macOS CI host, so they never enter the
   package. The pure snapshot model and its factory live in `AuraCore`; the
   App-Group file I/O lives in `AuraKit` (Foundation only); WidgetKit lives only
   in the extension and the one `WidgetCenter` call lives only in the app.

### Current state, confirmed in code

- `RideSummary` (`AuraCore/Sources/AuraCore/Models/RideSummary.swift`) is the
  lightweight, track-free projection: `id`, `kind`, `startedAt`, `endedAt`,
  `hasStats`, `distanceMeters`, `movingTimeSeconds`, `elevationGainMeters`,
  `destinationName`, and a simplified `thumbnailCoordinates: [Coordinate]`.
  `RideStore.summaries()` returns these newest-first without ever faulting a
  track blob.
- `RideAggregator` (`AuraCore/Sources/AuraKit/Home/RideAggregator.swift`) already
  carries the exact reductions the widget needs: `weekToDate(_:now:calendar:)`
  returns a `WeeklyRideStats` (distance, ride count, elevation, moving time) for
  the calendar week containing `now`, with `now`/`calendar` injectable; and
  `mostRecent(_:)` returns the newest `RideSummary?`. `WeeklyRideStats` carries
  `goalFraction(goalMeters:)` (clamped `0...1`) and `goalPercent(goalMeters:)`
  (uncapped).
- `SettingsStore.weeklyGoalMeters` (default ≈ 40 km) is the goal the home ring
  fills toward, stored unit-agnostically in meters. `SettingsStore.units`
  (`.imperial` default) is the rider's distance-units setting.
- `RideStatsFormatter` (`AuraCore/Sources/AuraKit/Formatting/`) is the unit-aware
  formatter the rest of the app and the Live Activity already use:
  `distanceValue`/`distanceUnit`, `elevationValue`/`elevationUnit`, `minutes`,
  `clock`, plus the spoken variants.
- `RouteThumbnail` (`Aura/Sources/Shared/RouteThumbnail.swift`) draws a track as a
  normalized `Canvas` polyline via `PolylineNormalizer.points` (AuraKit Plotting),
  stroked in `AuraTheme.routeLine` with an overridable `lineColor`/`lineWidth`. It
  imports only AuraCore + AuraKit, so it shares into the extension cleanly.
- `WeeklyRing` (`Aura/Sources/Plan/WeeklyRing.swift`) is the home dashboard's ring:
  a faint `AuraTheme.border` track under a lime `Circle().trim(from:0,to:fraction)`
  arc starting at 12 o'clock, with the week's distance as a Saira cockpit numeral
  in the center, and a composed VoiceOver label
  ("Distance this week" / "<value> <unit>, <percent> percent of weekly goal").
- `AuraWidgetBundle` (`Aura/Widgets/AuraWidgetBundle.swift`) is the `@main`
  `WidgetBundle`; its `body` returns `RideLiveActivity()` today.
- `Aura/Resources/Aura.entitlements` carries `com.apple.developer.healthkit`
  (from Wave 3 SP1), referenced by `CODE_SIGN_ENTITLEMENTS` in `project.yml` and
  excluded from the Resources copy. `AuraWidgets` has no entitlements file today.
- The `aura://` deep-link scheme (`AuraCore/Sources/AuraCore/Navigation/DeepLink.swift`)
  recognizes `plan` (home dashboard), `history`, `settings`, `ride` (pre-start
  free-ride HUD), and `preview` (a `Place`). `AuraApp` routes incoming URLs through
  `router.handle(url:)` via `.onOpenURL`. A deep link arriving mid-ride is ignored.
- CI runs three jobs: package `swift test` under Swift 6, an `xcodebuild` app build
  with `CODE_SIGNING_ALLOWED=NO` (which also builds `AuraWidgets`), and SwiftLint
  `--strict`.

## Decisions settled during brainstorming

The forks were settled toward the ambitious, low-risk choice, grounded in the
`widgetkit` and `impeccable` skills rather than recalled API.

1. **A denormalized Codable snapshot, not a shared SwiftData container.** The app
   writes a small `WidgetSnapshot` value (last-ride fields, weekly figures, the
   thumbnail polyline, units, the goal) into the App Group; the widget decodes it
   with no SwiftData stack at all. This keeps the versioned schema, the migration
   plan, and any Mapbox-touching decode out of the size-limited extension process,
   keeps the snapshot type pure and unit-testable, and mirrors how the Live
   Activity already works (the content carries the data). The cost — the app must
   write at the right moments and trigger a reload — is a small, explicit surface
   (decision 3).
2. **A `WidgetBundle` of two static widgets.** A "Last ride" widget and a "Weekly
   goal" widget, each independently addable and self-sizing, beside the existing
   Live Activity. This maps to the two data stories, each stays glanceable at
   small and accessory sizes (a combined widget gets cramped and cannot show both
   on a Lock Screen circle), and static keeps us out of App Intents — the rider
   configures nothing in v1.
3. **An app-level refresher, no coordinator change.** The widget snapshot is a
   read-projection of persisted state, so the app rebuilds and rewrites it when
   that state changes, the WidgetKit-idiomatic pattern. A thin app-target shim
   reads `RideStore.summaries()` + the relevant settings, writes the snapshot, and
   calls `WidgetCenter.shared.reloadAllTimelines()` at five points: a ride finish
   (via `.onChange(of: coordinator.finishedRide)` in both HUDs, which fires on
   every finish path including navigate arrival), a ride deletion in History, a
   weekly-goal change, a units change, and app launch + foreground
   (`scenePhase == .active`, which also catches a week rollover that happened while
   backgrounded). `RideSessionCoordinator` is untouched — threading a sixth seam
   through the ride lifecycle for a projection concern would be heavier than the
   app refreshing when its own data changes. The finish trigger is sound because
   `coordinator.finish()` saves synchronously (`try saving?.save(ride)`, a
   synchronous `throws`) *before* it sets `finishedRide = ride`, so by the time the
   `.onChange` fires, `summaries()` already includes the just-finished ride. The
   `.onChange` coexists with the existing `.sheet(item: $coordinator.finishedRide)`
   binding (the refresh is guarded on the new value being non-nil, so a sheet
   dismissal back to nil does not refresh).
4. **Two timeline entries with a week-boundary reset.** The provider reads the
   snapshot and never fetches. It emits an entry for *now* (the stored weekly
   figures) and a second entry dated at the snapshot's `week.end` that renders the
   weekly progress reset to zero for the new week (the last-ride widget is
   unaffected), with reload policy `.after(week.end)`. The app-driven reloads are
   the primary freshness path; the boundary entry self-corrects the "this week"
   total if the app stays closed across Sunday midnight. This sits far under
   WidgetKit's 40–70 reloads/day budget (a handful of entries per week).
5. **An App Group on both targets, wired through XcodeGen like HealthKit.** Group
   id `group.app.aura.ios`, exposed as a shared `AppGroup.identifier` constant in
   `AuraKit`. The app's `Aura.entitlements` gains the `application-groups` array
   (keeping HealthKit), and a new `AuraWidgets.entitlements` carries the same
   group. Both are committed files referenced by `CODE_SIGN_ENTITLEMENTS` and
   excluded from their target's sources copy. The entitlement is consumed at sign
   time, so CI's unsigned build still compiles; the App Group container only
   resolves when the entitlement is baked at link time, so simulator verification
   builds signed with the team (the link-time gotcha HealthKit already documented).
6. **Static, not configurable.** No `AppIntentConfiguration`, no App Intents, no
   Control Center control, no widget push. The two glances are fixed; YAGNI holds
   for v1. Configurability and a Control are noted as fast-follows.

## The pure layer, the bridge, and the extension

The split puts every decision that can be tested into the package and leaves the
extension a thin set of views over a decoded value.

### `AuraKit` — the snapshot and its factory

The snapshot lives in `AuraKit`, not `AuraCore`: it references `DistanceUnits`
(AuraKit) and its `Week.fraction`/`percent` reuse `WeeklyRideStats` (AuraKit), and
the factory calls `RideAggregator` (AuraKit). AuraKit is still in the SwiftPM
package and still builds and unit-tests on the macOS CI host (it imports no
SwiftUI/UIKit/WidgetKit), so the snapshot stays fully testable; this just avoids
an AuraCore-to-AuraKit dependency inversion.

- **`WidgetSnapshot`** (`AuraCore/Sources/AuraKit/Widgets/WidgetSnapshot.swift`)
  — a `Codable, Equatable, Sendable` value describing exactly what the widgets
  render, with no WidgetKit, SwiftData, or CoreLocation in sight:

  ```swift
  public struct WidgetSnapshot: Codable, Equatable, Sendable {
      /// Bumped if the stored shape changes; a reader rejects an unknown version
      /// (so a new widget binary ignores a snapshot an old app wrote, and vice
      /// versa, until the app rewrites it).
      public static let currentVersion = 1

      public struct LastRide: Codable, Equatable, Sendable {
          public let id: UUID
          public let kind: Ride.Kind
          public let startedAt: Date
          public let hasStats: Bool
          public let distanceMeters: Double
          public let movingTimeSeconds: Double
          public let elevationGainMeters: Double
          public let destinationName: String?
          public let thumbnailCoordinates: [Coordinate]
          // memberwise init …
      }

      public struct Week: Codable, Equatable, Sendable {
          public let distanceMeters: Double
          public let rideCount: Int
          public let goalMeters: Double
          public let start: Date
          public let end: Date
          // memberwise init …

          /// Reuses the home dashboard's clamped goal math — no duplication.
          public var fraction: Double {
              WeeklyRideStats(distanceMeters: distanceMeters, rideCount: rideCount,
                              elevationGainMeters: 0, movingTimeSeconds: 0)
                  .goalFraction(goalMeters: goalMeters)
          }
          public var percent: Int {
              WeeklyRideStats(distanceMeters: distanceMeters, rideCount: rideCount,
                              elevationGainMeters: 0, movingTimeSeconds: 0)
                  .goalPercent(goalMeters: goalMeters)
          }
      }

      public let version: Int
      public let generatedAt: Date
      public let units: DistanceUnits
      public let lastRide: LastRide?   // nil when there are no saved rides
      public let week: Week
      // memberwise init defaulting version: Self.currentVersion …
  }
  ```

- **`WidgetSnapshot.make(summaries:goalMeters:units:now:calendar:)`** — a pure
  factory built entirely from the existing reductions:
  - `week` from `RideAggregator.weekToDate(summaries, now:, calendar:)` plus the
    `DateInterval` from `calendar.dateInterval(of: .weekOfYear, for: now)` (falling
    back to `now...now` if the calendar returns nil, so the type stays total);
  - `lastRide` mapped from `RideAggregator.mostRecent(summaries)` (nil when empty);
    its `thumbnailCoordinates` come straight from `RideSummary`, already capped at
    ≤ 60 points by `TrackSimplifier.thumbnail(maxPoints: 60)` at persistence time,
    so the snapshot JSON stays small and the extension decodes a bounded array;
  - `units` and `generatedAt: now` passed through (`now`, not `Date()`, so the
    factory is deterministic and testable).
- **`WidgetSnapshot.weekReset()`** — returns a copy with `week.distanceMeters = 0`
  and `week.rideCount = 0` (goal and interval unchanged, `lastRide` unchanged), for
  the provider's week-boundary entry.
- **`WidgetSnapshot.sample`** — a canned snapshot for the provider's synchronous
  `placeholder(in:)` and for previews.

### `AuraKit` — the App Group store

- **`AppGroup`** (`AuraCore/Sources/AuraKit/Widgets/WidgetSnapshotStore.swift`) —
  `public enum AppGroup { public static let identifier = "group.app.aura.ios" }`.
- **`WidgetSnapshotStore`** — a small value type that encodes/decodes the snapshot
  as JSON in a directory, with the directory injected so it is testable on the
  macOS CI host (the App Group container is `nil` there):

  ```swift
  public struct WidgetSnapshotStore {
      private let directory: URL?
      private let fileName = "widget-snapshot.json"

      /// Inject a directory in tests; production resolves the App Group container.
      public init(directory: URL?) { self.directory = directory }

      /// The shared App-Group-backed store the app writes and the widget reads.
      public static func appGroup() -> WidgetSnapshotStore {
          WidgetSnapshotStore(directory:
              FileManager.default.containerURL(
                  forSecurityApplicationGroupIdentifier: AppGroup.identifier))
      }

      public func write(_ snapshot: WidgetSnapshot) {
          guard let url = fileURL else { return }
          guard let data = try? JSONEncoder().encode(snapshot) else { return }
          try? data.write(to: url, options: .atomic)
      }

      /// Returns nil when the container is unavailable, the file is missing, the
      /// JSON fails to decode, or the version is unrecognized — every failure
      /// folds to "no snapshot", which the views render as their empty state.
      public func read() -> WidgetSnapshot? {
          guard let url = fileURL, let data = try? Data(contentsOf: url),
                let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data),
                snapshot.version == WidgetSnapshot.currentVersion else { return nil }
          return snapshot
      }

      private var fileURL: URL? { directory?.appendingPathComponent(fileName) }
  }
  ```

  `FileManager.containerURL(...)` and `JSONEncoder`/`Decoder` are Foundation, so
  no `#if os(iOS)` guard is needed; on macOS the container URL is simply nil and
  the store no-ops, which the tests exercise with a real temp directory instead.

### `Aura` app target — the refresher

- **`WidgetRefresh`** (`Aura/Sources/Widgets/WidgetRefresh.swift`, new) — a
  `@MainActor enum` with one entry point that rebuilds and republishes the
  snapshot, then asks WidgetKit to reload:

  ```swift
  @MainActor
  enum WidgetRefresh {
      private static let store = WidgetSnapshotStore.appGroup()

      static func reload(rideStore: RideStore, settings: SettingsStore,
                         now: Date = Date()) {
          let summaries = (try? rideStore.summaries()) ?? []
          let snapshot = WidgetSnapshot.make(summaries: summaries,
                                             goalMeters: settings.weeklyGoalMeters,
                                             units: settings.units, now: now)
          store.write(snapshot)
          WidgetCenter.shared.reloadAllTimelines()
      }
  }
  ```

  `WidgetCenter` is the only WidgetKit symbol in the app target. A failed
  `summaries()` read degrades to an empty-state snapshot rather than throwing.
- **Trigger sites** (each already has `rideStore`/`settings` in the environment):
  - `AuraApp`/`RootView`: an initial `reload` in `.task` and a
    `.onChange(of: scenePhase)` that reloads on `.active`.
  - `RideHUDView` and `NavigateHUDView`:
    `.onChange(of: coordinator.finishedRide) { _, ride in if ride != nil { WidgetRefresh.reload(...) } }`.
  - `HistoryView`: after a successful delete (`rideStore.delete(id:)` in the
    existing swipe/delete action), call `WidgetRefresh.reload(...)` so removing the
    most recent ride (or any ride this week) updates both widgets without waiting
    for the next foreground.
  - `SettingsView`: `.onChange(of: settings.weeklyGoalMeters)` and
    `.onChange(of: settings.units)` both reload.

### `AuraWidgets` — the providers, entries, and views

- **`SnapshotEntry`** (`Aura/Widgets/WidgetTimeline.swift`) — `TimelineEntry`:
  `let date: Date; let snapshot: WidgetSnapshot?`. Shared by both widgets.
- **`SnapshotProvider: TimelineProvider`** — one provider type, two instances:
  - `placeholder(in:)` → `SnapshotEntry(date: .now, snapshot: .sample)` (synchronous).
  - `getSnapshot(in:)` → `context.isPreview ? .sample : (store.read() ?? .sample)`.
  - `getTimeline(in:)` → reads `WidgetSnapshotStore.appGroup().read()`. With a
    snapshot: two entries — `(now, snapshot)` and `(snapshot.week.end,
    snapshot.weekReset())` — policy `.after(snapshot.week.end)`. With nil: a single
    `(now, nil)` entry, policy `.atEnd` (the next app reload refills it).
- **`WeeklyGoalWidget`** and **`LastRideWidget`** — each a `Widget` with a
  `StaticConfiguration(kind:provider:)`, a `configurationDisplayName`/`description`,
  and `supportedFamilies`. Registered in `AuraWidgetBundle` beside
  `RideLiveActivity()`.

  Kinds: `"app.aura.widgets.weeklyGoal"`, `"app.aura.widgets.lastRide"`.

## Widget surface

All text formats through `RideStatsFormatter(units: snapshot.units)`, so every
widget honors the rider's distance-units setting. Lock Screen accessory families
render in `.vibrant`/`.accented` mode, so they lean on shape and
`.widgetAccentable()`, not the lime color, and use `AccessoryWidgetBackground`
or a system `Gauge`. Copy is sentence case, tight, no terminal punctuation on
labels.

### Weekly goal — `systemSmall`, `accessoryCircular`, `accessoryRectangular`, `accessoryInline`

- **`systemSmall`** — the `WeeklyRing` voice, miniaturized: a faint track under a
  lime `Circle().trim` arc, the week's distance as a Saira cockpit numeral
  (`AuraTheme.Typography.metricCockpit`) over a small "MI THIS WEEK"-style unit
  label, and a lime "<percent>% of <goal> <unit>" plus the ride count beneath.
  `.containerBackground(AuraTheme.background, for: .widget)`. Deep links to
  `aura://plan`.
- **`accessoryCircular`** — `Gauge(value: snapshot.week.fraction, in: 0...1)` with
  `.gaugeStyle(.accessoryCircular)`, the distance as the `currentValueLabel`,
  `.widgetAccentable()`. The system handles the vibrant ring. `fraction` is clamped
  to 1.0, so an over-goal week shows a full ring while the value label still reads
  the actual distance (intended).
- **`accessoryRectangular`** — a "This week" line, the value "<dist> / <goal> <unit>",
  a `Gauge(value: fraction, in: 0...1).gaugeStyle(.accessoryLinearCapacity)` bar,
  and a "<percent>% · <n> rides" line. `.widgetAccentable()`.
- **`accessoryInline`** — `Label("<dist> of <goal> <unit> this week", systemImage:
  "bicycle")` (inline supports one image + text, shown beside the clock).

### Last ride — `systemSmall`, `systemMedium`, `accessoryRectangular`

- **`systemSmall`** — the `RouteThumbnail` of `lastRide.thumbnailCoordinates` as a
  small lime polyline, the distance as a Saira hero numeral with a "mi"/"km" unit,
  and a "<weekday> · <kind>" caption (kind: "Free ride" / the destination name for
  a navigated ride). `aura://history`.
- **`systemMedium`** — the `LastRideCard` voice: the thumbnail on the leading side,
  the hero distance and "Last ride · <weekday>" beneath it, and a hairline-divided
  stat column on the trailing side (moving time, climbed; and a third stat when it
  fits). `hasStats == false` shows "—" for the stat values, matching the app.
- **`accessoryRectangular`** — a small monochrome thumbnail (or a leading SF Symbol
  when rendering mode is vibrant), a "Last ride · <weekday>" line, the hero "<dist>
  <unit>", and a "<time> · <climb> climb" line. `.widgetAccentable()`.

### Empty state and placeholder

- **No saved rides** (`snapshot == nil` or `lastRide == nil`): the Last ride widget
  shows an invitation — a bicycle glyph, "No rides yet", and a short "Start a ride"
  prompt — that deep links to `aura://ride`. The Weekly goal widget renders the
  ring at 0 with "0% of <goal> <unit>" and "No rides yet" (the goal is still
  meaningful before the first ride).
- **Placeholder** (gallery / redacted): the synchronous `WidgetSnapshot.sample`,
  so the gallery preview reads as real content with believable numbers.

## TimelineProvider model

- Entries: `[(now, snapshot)]` plus `[(week.end, weekReset)]` when a snapshot
  exists, else `[(now, nil)]`. `week.end` is the half-open `DateInterval.end` from
  `Calendar.dateInterval(of: .weekOfYear)`, i.e. the first instant of the next week,
  so the second entry renders at the moment the week turns over. `weekReset()`
  zeroes the figures but keeps the *old* interval; the app's next reload (or the
  policy below) rewrites the snapshot with the new week's interval, so the stale
  boundary is corrected promptly.
- Policy: `.after(week.end)` with a snapshot (so the boundary entry is followed by
  a refresh that recomputes "this week" even with the app unopened); `.atEnd`
  without one.
- Freshness primarily comes from the app's `reloadAllTimelines()` on finish, goal
  change, units change, and foreground (decision 3). The provider does no I/O
  beyond the single synchronous `store.read()`; `placeholder` is synchronous.
- Smart Stack relevance, push reloads, and `widgetAccentedRenderingMode` image
  tuning are out of scope for v1 (noted as fast-follows).

## App Group, entitlements, and XcodeGen

- **`Aura/Resources/Aura.entitlements`** gains:

  ```xml
  <key>com.apple.security.application-groups</key>
  <array><string>group.app.aura.ios</string></array>
  ```

  keeping the existing `com.apple.developer.healthkit`.
- **`Aura/Widgets/AuraWidgets.entitlements`** (new, committed) carries the same
  `application-groups` array and nothing else.
- **`Aura/project.yml`**:
  - the `AuraWidgets` target gains `CODE_SIGN_ENTITLEMENTS: Widgets/AuraWidgets.entitlements`
    in `settings.base` and adds `AuraWidgets.entitlements` to the `Widgets`
    `excludes` (so XcodeGen does not classify it as a resource);
  - the `AuraWidgets` `sources` add `- path: Sources/Shared/RouteThumbnail.swift`
    (shared by target membership, like the theme files);
  - the app target's `CODE_SIGN_ENTITLEMENTS` is unchanged (the array is added
    inside the already-referenced file).
- **CI tolerance.** App Groups are applied at code-sign time, which the app build
  skips (`CODE_SIGNING_ALLOWED=NO`). `import WidgetKit` compiles against the SDK on
  the CI host, so the build (which also builds `AuraWidgets`) stays green.
- **What needs a `project.yml` change vs. what is auto-globbed.** XcodeGen expands
  globs at generation time, so `xcodegen generate` is required after *any* file
  add, but most new files need no `project.yml` edit: new widget files under
  `Aura/Widgets/**` (`WidgetTimeline.swift`, the two widget files) are already
  covered by the existing `- path: Widgets` source glob, and `WidgetRefresh.swift`
  under `Aura/Sources/**` is covered by the app target's `- Sources` glob. Only
  three things touch `project.yml`: the `RouteThumbnail.swift` path entry under
  `AuraWidgets` `sources` (it lives in `Sources/Shared/`, outside `Widgets/`), the
  `AuraWidgets.entitlements` exclude + `CODE_SIGN_ENTITLEMENTS`, and the app's
  `Aura.entitlements` is edited in place (no `project.yml` change, since
  `CODE_SIGN_ENTITLEMENTS` already points at it). The package files under
  `AuraCore/Sources/**` are auto-globbed by SwiftPM and never touch `project.yml`.
  The `@main` `WidgetBundle` stays the only `@main` in the extension —
  `RouteThumbnail` and the widget files are plain types, so there is no
  duplicate-entry-point risk.

## Accessibility and design

Widgets are real visual UI, so the design skills apply (honoring `AuraTheme`, no
new palette):

- **Composed VoiceOver labels**, one per widget (the whole widget is a single tap
  target): the Weekly goal widget reuses the `WeeklyRing` phrasing ("Distance this
  week, <value> <unit>, <percent> percent of weekly goal"); the Last ride widget
  reads "Last ride, <weekday>, <distance> <unit>" plus moving time when present.
  The thumbnail is `accessibilityHidden`.
- **Dynamic Type:** text uses the cockpit/brand type roles that scale via
  `relativeTo:`, with `minimumScaleFactor` and `lineLimit(1)` so the glanceable
  numerals stay within the fixed widget bounds at accessibility sizes.
- **Contrast:** the Home Screen widgets render full-color on `AuraTheme.background`
  (near-black) with lime and the contrast-checked `textSecondary` (0.62 white) —
  the same WCAG-guarded tokens the app ships. Lock Screen families render
  monochrome via the system rendering mode, so legibility comes from shape and the
  system's own vibrant treatment, with `.widgetAccentable()` marking the lime
  elements as the accent.
- **No motion** in the widgets (timeline widgets do not animate), so no Reduce
  Motion branch is needed.

## CI-safety

- `WidgetSnapshot`, its factory, `weekReset`, and `sample` are pure `AuraKit`
  (Foundation plus the AuraCore/AuraKit models, no SwiftUI/UIKit/WidgetKit). Build
  and test on macOS.
- `WidgetSnapshotStore` imports only Foundation; the App Group container URL is nil
  on macOS and the store no-ops, while the tests inject a temp directory and
  exercise the real encode/write/read/decode path. No WidgetKit in the package.
- Every WidgetKit symbol (`TimelineProvider`, `StaticConfiguration`, `Gauge` in
  widget context, `AccessoryWidgetBackground`, `WidgetCenter`) lives in the
  extension or the app target, compiled only for iOS.

## Testing

The pure layer carries the unit tests; the widgets are verified on the simulator.

- **`AuraKit` (Swift Testing) — `WidgetSnapshotTests`:**
  - `make` derives `lastRide` from `mostRecent` and the week figures from
    `weekToDate` (a fixed `now`/`calendar`), carries `goalMeters`, `units`, and the
    week `DateInterval`;
  - empty summaries → `lastRide == nil` and a zeroed `week` with the goal still set;
  - a statless most-recent ride carries `hasStats == false` and zero stat values;
  - `Week.fraction`/`percent` match `WeeklyRideStats` (including over-goal `> 100%`
    and a zero/negative goal guarded to 0);
  - `weekReset()` zeroes `week.distanceMeters`/`rideCount`, preserves goal,
    interval, and `lastRide`;
  - Codable round-trip: encode then decode equals the original (including `version`
    and `thumbnailCoordinates`).
- **`AuraKit` (Swift Testing) — `WidgetSnapshotStoreTests`** (inject a temp
  directory):
  - `write` then `read` returns an equal snapshot;
  - `read` returns nil when the file is absent;
  - `read` returns nil on a corrupt file and on a version mismatch (write a
    hand-rolled JSON with a different `version`);
  - a store built with a nil directory no-ops on `write` and returns nil on `read`.
- **CI gates** carry the extension and app code: the package tests, the
  `xcodebuild` build (which proves the providers, the views, `import WidgetKit`,
  the `WidgetCenter` call, and both entitlements compile unsigned), and SwiftLint
  `--strict` over the whole repo at every task gate.
- **Simulator verification on iPhone 17 / iOS 26** is the real-result check a clean
  build cannot give, built **signed** (`CODE_SIGN_STYLE=Automatic
  DEVELOPMENT_TEAM=Y9HGZ8Z97R`) so the App Group container resolves:
  - add each widget at each family from the gallery to the **Home Screen** and the
    **Lock Screen**, and confirm it shows the real last ride and the real
    weekly-goal progress (drive a ride or seed rides, then read back);
  - finish a new ride and confirm the widgets update (snapshot rewritten +
    `reloadAllTimelines`), via screenshots and the accessibility tree;
  - confirm the empty state (a fresh install with no rides) and the units-change
    and goal-change refreshes;
  - the build-dir rule (install the build whose `TARGET_BUILD_DIR` is authoritative,
    not by mtime) and the reboot-on-stale-frame rule apply.
  - A final holistic review runs on the most capable model.

## Risks and mitigations

- **Stale snapshot across an app update.** A new widget binary could read a
  snapshot an older app wrote (or vice versa). The `version` field gates this:
  `read()` returns nil on a mismatch, so the widget shows its empty/placeholder
  state until the app rewrites on next launch. Unit-tested.
- **The App Group container is nil without the entitlement.** `containerURL`
  returns nil unsigned or unentitled, so `write`/`read` no-op rather than crash; CI
  never resolves it, and simulator verification builds signed. Both paths are
  named, not assumed.
- **Transient read during an atomic write.** `.atomic` writes rename a temp file
  into place, so a concurrent reader sees the old or the new file whole, never a
  torn one. The one residual case is a `Data(contentsOf:)` that opens during the
  rename and throws, which `read()` folds to nil and the widget would render as the
  empty state for a single timeline build. This is rare and self-heals on the next
  reload; it is accepted rather than guarded with a last-known-good cache, to keep
  the store a plain value type.
- **The empty-state deep link is a no-op mid-ride.** The Last ride widget's
  "Start a ride" links to `aura://ride`, which `router.handle(url:)` ignores while a
  ride is recording (the `isRideActive` guard). This only matters during a rider's
  very first ride (the empty state shows only before any ride is saved), so the
  degradation is acceptable and the link is intentionally left as is.
- **Refresh budget.** All freshness is app-driven plus one week-boundary entry, so
  the widget never approaches WidgetKit's 40–70/day reload budget; `reloadAllTimelines`
  is called only on genuine data changes.
- **The write must never affect a ride.** `WidgetRefresh.reload` reads `summaries()`
  (the cheap projection, never the track) and writes a file; it is called after the
  coordinator has already saved and published, and a failed read degrades to an
  empty snapshot. It touches no ride or save state.
- **Simulator cannot prove StandBy.** StandBy rendering is a device-only surface
  (like Wave 0's locked-screen recording and the haptic feel); it is named as a
  device-only boundary, and the small-system and accessory families are fully
  exercisable on the simulator.

## Out of scope

- `AppIntentConfiguration`/App Intents (a configurable "which ride" widget), a
  Control Center control, and widget push reloads — fast-follows on the same
  bundle.
- A shared SwiftData container in the App Group (the snapshot replaces it).
- Any new `aura://` route, a deep link to a specific saved ride's detail (there is
  no route for one today), Smart Stack relevance scoring, or `widgetAccentedRenderingMode`
  image tuning.
- Any change to `RideSessionCoordinator`, the Live Activity, the cockpit, the ride
  summary, or the persistence layer.

## Rough task order

1. `AuraKit`: `WidgetSnapshot` (+ `LastRide`/`Week`, `fraction`/`percent`),
   `make(...)`, `weekReset()`, `sample`, TDD.
2. `AuraKit`: `AppGroup.identifier` + `WidgetSnapshotStore` (directory-injected),
   TDD with a temp directory.
3. App target: `WidgetRefresh` and its five trigger sites (app launch/foreground,
   both HUDs' `finishedRide`, History delete, Settings goal + units).
4. `AuraWidgets`: `SnapshotEntry` + `SnapshotProvider` + `WidgetTimeline.swift`;
   share `RouteThumbnail` into the target.
5. `AuraWidgets`: `WeeklyGoalWidget` (4 families) + `LastRideWidget` (3 families) +
   register both in `AuraWidgetBundle`; composed VoiceOver labels and deep links.
6. `project.yml` + `Aura.entitlements` (app-groups) + `AuraWidgets.entitlements`
   (new) + the `RouteThumbnail` membership and the widget file adds; `xcodegen
   generate`.
7. Simulator verification (Home + Lock at every family, real data, update after a
   finish, empty state, units/goal refresh), built signed; then a final holistic
   review.
8. Mark Wave 3 item 3 shipped in the ROADMAP and note Wave 3 COMPLETE.
