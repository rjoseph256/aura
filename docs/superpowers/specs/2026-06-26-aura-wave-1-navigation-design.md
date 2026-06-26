# Aura Wave 1 — Navigation: design

**Goal:** Replace the hand-rolled `AppRouter.screen` enum and the top-level `switch`
in `RootView` with a `NavigationStack(path:)` over a typed `AppRoute` enum and one
`.navigationDestination`. `AppRouter` stays the `@MainActor @Observable` owner of the
path and gains a `handle(url:)` entry point for deep links. The move to a real stack
also ends the per-transition Mapbox map teardown that the current switch forces on
every screen change.

**Status:** approved design, ready to plan.

## Context

Wave 1 is the structural-foundations wave, five sub-projects in build order: quality
gates, design system, ride-session coordinator, persistence, navigation. The first
four shipped (PRs #3, #4, #5, #6). This is the fifth and last. The 2026-06-24 audit
called navigation "the largest rebuild item" and "the one that unblocks several
others," so it carries more risk than the prior four. Scope is navigation only. No
group ride, no new screens, no HUD visual changes.

The app has three compiled layers plus the widget extension:

- `AuraCore`: pure Swift models and protocols, no UIKit or SwiftUI. Builds on the
  macOS CI host, so anything added here is unit-tested in CI.
- `AuraKit`: depends on `AuraCore`, may import CoreLocation, imports no SwiftUI.
- `Aura`: the app target. SwiftUI plus the Mapbox-backed implementations. The
  `NavigationStack` lives here.
- `AuraWidgets`: the WidgetKit extension. Untouched by this work.

Current state, confirmed in code:

- `AppRouter` (`Aura/Sources/App/AppRouter.swift`) is `@MainActor @Observable`. It
  holds `screen: Screen` (`.plan` / `.preview(Place)` / `.ride(route: Route?, destination: Place?)`),
  `selectedTab: Tab`, and a persisted `recents: [Place]` with `remember(_:)`.
- `RootView` (`Aura/Sources/AuraApp.swift`) renders a `switch router.screen` wrapped
  in `.animation(.easeInOut(duration: 0.25), value: router.screen)`. `.plan` shows
  `AuraTabView` (a `TabView` over Ride / History / Settings, where History and
  Settings each already wrap their content in their own `NavigationStack`). `.preview`
  and `.ride` swap the whole window to a full-screen view.
- Eight call sites drive navigation by assigning `router.screen`: two in `PlanView`
  (search result and recents row, both to `.preview`) plus the free-ride button (to
  `.ride(route: nil, ...)`), three in `RoutePreviewView` (two backs to `.plan`, one
  Start to `.ride`), one in `NavigateHUDView` (summary dismiss to `.plan`), and two in
  `RideHUDView` (summary dismiss and the pre-start back button, both to `.plan`).
- Each of `RoutePreviewView`, `RideHUDView` (through `RideMapView`), and
  `NavigateHUDView` owns its own Mapbox `Map`. Because the `switch` swaps the entire
  subtree on every transition, each transition dismantles the outgoing map and builds
  the incoming one.
- `AuraCore.Route` is a value type with a full `geometry: [Coordinate]` and an
  `elevationProfile: [Double]`. `Place`, `Route`, and `Coordinate` are `Equatable`,
  `Codable`, and `Sendable`, but not `Hashable`.
- The app declares no `CFBundleURLTypes`, so no URL scheme is registered today.

The central tension: a `NavigationStack` path element must be `Hashable`, but the
route the rider is navigating carries a whole `Route`, which is heavy and not
`Hashable`. The design resolves this by hashing on stable ids rather than on the
route's contents, so the path stays cheap without making the core models hash their
geometry.

## Decisions settled during brainstorming

1. **Per-tab stack, push flow.** The `TabView` stays at the root. The Ride tab becomes
   a `NavigationStack(path: $router.path)` rooted at `PlanView`, with one
   `.navigationDestination(for: AppRoute.self)`. Preview and the ride HUDs are pushed
   destinations. History and Settings keep their own stacks. Returning to the home
   dashboard is a pop to root. A single stack over the tabs, and modal `fullScreenCover`
   presentations, were both rejected: the first shares one path across tabs against
   Apple's per-tab guidance, and the second gives no back-swipe and cannot put a ride
   on an appendable, URL-addressable path.

2. **`AppRoute` in AuraCore, carrying the full route, hashed by id.** The typed enum is
   named `AppRoute` to avoid the clash with `AuraCore.Route`, and it lives in AuraCore
   as a pure enum so the URL parser beside it is unit-tested in CI. It carries the full
   `Route` for the navigate case, mirroring today's `Screen.ride(route:)`, so the route
   travels with the path and there is no separate route store to fall out of sync. Its
   `Equatable` and `Hashable` are written by hand against `place.id` / `route.id`, so
   neither `Place` nor `Route` nor `Coordinate` gains a conformance and no geometry is
   ever hashed. A lightweight enum that resolves the route from a holder was rejected:
   it adds a store plus a missing-route fallback in the live-ride path, the riskiest
   place to add a branch. Defining the enum in the app target was rejected because it
   would put the URL parser out of reach of the package test suite.

3. **`aura://` custom scheme for deep links.** The addressable surface is the Ride home,
   the History and Settings tabs, a pre-start free ride, and a route preview to a
   destination given by coordinate and name. Navigating a specific computed route is not
   addressable, because a URL cannot carry a geometry; a deep link reaches preview, which
   then computes routes. Universal (https) links were rejected for now: they need an
   Associated Domains entitlement and a hosted apple-app-site-association file that this
   private app does not have.

4. **Lean on stack retention for the map, no shared map.** The end of per-transition
   teardown comes from the push model itself: pushing a destination does not dismantle
   the screen beneath it, and popping restores it without a rebuild. No shared-map
   plumbing is added. Hoisting a single Mapbox map behind the whole flow is recorded as
   a fast-follow rather than bundled into the last structural item.

5. **Back-swipe is suppressed only while recording.** Before a ride starts, the
   interactive back-swipe and the in-content back button both pop, matching today's
   pre-start back affordance on the free-ride HUD. Once recording, the interactive pop
   gesture is disabled so a stray edge swipe on a mounted phone cannot abandon the ride.
   The exits from an active ride stay End ride and arrival.

## `AppRoute`

A pure enum in `AuraCore/Sources/AuraCore/Navigation/AppRoute.swift`:

```swift
public enum AppRoute: Sendable {
    case freeRide
    case preview(Place)
    case navigate(route: Route, destination: Place?)
}

extension AppRoute: Hashable {
    public static func == (lhs: AppRoute, rhs: AppRoute) -> Bool {
        switch (lhs, rhs) {
        case (.freeRide, .freeRide):
            return true
        case let (.preview(a), .preview(b)):
            return a.id == b.id
        case let (.navigate(ra, da), .navigate(rb, db)):
            return ra.id == rb.id && da?.id == db?.id
        default:
            return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .freeRide:
            hasher.combine(0)
        case let .preview(place):
            hasher.combine(1)
            hasher.combine(place.id)
        case let .navigate(route, destination):
            hasher.combine(2)
            hasher.combine(route.id)
            hasher.combine(destination?.id)
        }
    }
}
```

`freeRide` and `navigate` replace today's single `.ride(route: Route?, ...)`, where a
nil route meant a free ride. Splitting them removes the optional-route branch from the
destination builder.

The identity is the case plus the stable ids, not the payload contents. Two `preview`
values for the same place id are equal and hash equal even if some other field differs,
which is the correct notion of identity for a navigation entry. Equality stays
consistent with the hash: equal values share their ids, so they share their hash.

## `DeepLink` and the parser

A pure parser in `AuraCore/Sources/AuraCore/Navigation/DeepLink.swift` turns a URL into
an intent. It is a separate type from `AppRoute` because two of its cases select a tab
rather than push a route, so it is not a subset of the path element.

```swift
public enum DeepLink: Equatable, Sendable {
    case home          // Ride tab, pop to root
    case history
    case settings
    case freeRide      // Ride tab, pre-start free-ride HUD
    case preview(Place)

    /// Parses an `aura://…` URL. Returns nil for any scheme, host, or parameter set
    /// the app does not recognize, so an unknown link is a no-op rather than a guess.
    public static func parse(_ url: URL) -> DeepLink?
}
```

Recognized URLs:

| URL | Intent |
| --- | --- |
| `aura://plan` | `.home` |
| `aura://history` | `.history` |
| `aura://settings` | `.settings` |
| `aura://ride` | `.freeRide` |
| `aura://preview?lat=<d>&lng=<d>&name=<s>` | `.preview(Place)` |

The parser checks the scheme is `aura`, switches on the host, and for `preview` reads
`lat`, `lng`, and `name` from the query. A missing or non-numeric `lat`/`lng`, a missing
`name`, an unknown host, or a wrong scheme all return nil. The `Place` it builds gets a
fresh `id`, the given name and coordinate, and the `.custom` category, matching how a
typed-in destination is modeled elsewhere.

## `AppRouter`

`Screen` is removed. `selectedTab`, `recents`, and `remember(_:)` are unchanged. The
path and its helpers are added:

```swift
var path: [AppRoute] = []

func push(_ route: AppRoute) { path.append(route) }
func pop() { if !path.isEmpty { path.removeLast() } }
func popToRoot() { path.removeAll() }

func handle(url: URL) {
    guard let link = DeepLink.parse(url) else { return }
    switch link {
    case .home:
        selectedTab = .ride
        path.removeAll()
    case .history:
        selectedTab = .history
    case .settings:
        selectedTab = .settings
    case .freeRide:
        selectedTab = .ride
        path = [.freeRide]
    case let .preview(place):
        remember(place)
        selectedTab = .ride
        path = [.preview(place)]
    }
}
```

A deep link resets the Ride tab's path to a single element rather than appending, so an
incoming link lands on a clean stack instead of stacking onto whatever the rider had
open. `handle(url:)` is thin glue over the tested parser; the string parsing it depends
on is the part with the bugs, and that part is in AuraCore under test.

## Composition

`RootView` becomes the tab shell directly, and the old private `AuraTabView` folds into
it:

```swift
private struct RootView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            NavigationStack(path: $router.path) {
                PlanView()
                    .navigationDestination(for: AppRoute.self) { route in
                        switch route {
                        case .freeRide:
                            RideHUDView()
                        case let .preview(place):
                            RoutePreviewView(destination: place)
                        case let .navigate(route, destination):
                            NavigateHUDView(route: route, destination: destination)
                        }
                    }
            }
            .tabItem { Label("Ride", systemImage: "bicycle") }
            .tag(AppRouter.Tab.ride)

            NavigationStack { HistoryView() }
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(AppRouter.Tab.history)

            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(AppRouter.Tab.settings)
        }
        .tint(AuraTheme.accent)
    }
}
```

The `.tabItem` / `.tag` API stays, rather than the iOS 18 `Tab(value:)` API, because the
deployment target is iOS 17. The `.animation(value: router.screen)` cross-fade is gone;
push and pop use the system transition, which is interruptible and honors Reduce Motion
on its own.

`AuraApp` adds the deep-link hook on the `RootView`:

```swift
RootView()
    .environment(router)
    // … existing environment …
    .onOpenURL { router.handle(url: $0) }
```

## Full-screen chrome and the back gesture

The pushed `preview` and HUD destinations are full-bleed, so each hides the navigation
bar and the tab bar and keeps its own in-content controls:

```swift
.toolbar(.hidden, for: .navigationBar)
.toolbar(.hidden, for: .tabBar)
.navigationBarBackButtonHidden(true)
```

Hiding the navigation bar this way leaves the interactive back-swipe working in a
`NavigationStack`, which is what preview wants. The ride HUDs need the swipe gone while
recording, which the toolbar modifiers do not do on their own. A small reusable modifier
backed by the hosting `UINavigationController` toggles
`interactivePopGestureRecognizer.isEnabled`:

```swift
// Aura/Sources/App/SwipeBackGesture.swift
extension View {
    /// Enables or disables the navigation stack's interactive pop (edge swipe) for the
    /// screen it is attached to. Used to keep an actively recording ride from being
    /// swiped away by accident.
    func swipeBackEnabled(_ enabled: Bool) -> some View {
        background(SwipeBackGestureToggle(enabled: enabled))
    }
}
```

`SwipeBackGestureToggle` is a `UIViewControllerRepresentable` whose `updateUIViewController`
walks to `navigationController?.interactivePopGestureRecognizer` and sets `isEnabled`.
The free-ride HUD applies `.swipeBackEnabled(!coordinator.isRecording)`; the navigate HUD
applies `.swipeBackEnabled(!coordinator.isRecording)` as well. Because reaching the
controller is the one piece of UIKit introspection here, the simulator smoke test
exercises both the recording and pre-start states directly.

## Wiring deltas

Every navigation assignment moves from `router.screen = …` to a path call. Behavior is
preserved at each site.

- `PlanView`: the search-result and recents-row handlers call
  `router.push(.preview(place))`; the free-ride button calls `router.push(.freeRide)`.
  The last-ride card still sets `router.selectedTab = .history` and does not touch the
  path.
- `RoutePreviewView`: both backs call `router.pop()`; Start calls
  `router.push(.navigate(route: selected, destination: destination))` inside the existing
  `selected != nil` guard.
- `RideHUDView`: the summary `onDismiss` and the pre-start back button call
  `router.popToRoot()`. The pre-start back button keeps showing only before recording.
  The view applies the full-screen chrome and `swipeBackEnabled`.
- `NavigateHUDView`: the summary `onDismiss` calls `router.popToRoot()`. The view applies
  the full-screen chrome and `swipeBackEnabled`.

## Behavior preservation

| Behavior | Before | After |
| --- | --- | --- |
| Tabs (Ride / History / Settings) | `AuraTabView` shown for `.plan` | same `TabView`, now the `RootView` body |
| Home → preview | `screen = .preview(place)` | `push(.preview(place))` |
| Home → free ride | `screen = .ride(route: nil, …)` | `push(.freeRide)` |
| Preview → navigate | `screen = .ride(route: selected, …)` | `push(.navigate(route: selected, …))` |
| Preview back | `screen = .plan` | `pop()` |
| Ride summary dismiss → home | `screen = .plan` | `popToRoot()` |
| Last-ride card → History | `selectedTab = .history` | unchanged |
| Transition animation | `.easeInOut` cross-fade of the whole subtree | system push/pop, Reduce-Motion aware |
| Mapbox map across a transition | dismantled and rebuilt | retained under the push, rebuilt only on pop |
| Pre-start back-swipe on a HUD | not applicable (no stack) | swipe and in-content back both pop |
| Back-swipe while recording | not applicable | suppressed; End ride and arrival are the exits |

## Testing

New tests are Swift Testing, matching the coordinator and persistence precedent. They
live in `AuraCore/Tests/AuraCoreTests/`, since `AppRoute` and `DeepLink` are AuraCore
types, and they run in the package job on the macOS CI host.

- `AppRoute`: `.freeRide` equals itself; two `preview` values are equal exactly when
  their place ids match; two `navigate` values are equal exactly when route id and
  destination id match; different cases are unequal; equal values hash equal. One test
  builds a `navigate` route with a large geometry and asserts equality is decided by id,
  not contents.
- `DeepLink.parse`: each recognized URL maps to its intent, including `preview` decoding
  `lat` / `lng` / `name` into a `Place` with the right coordinate, name, and `.custom`
  category. Unknown host, wrong scheme, missing or non-numeric `lat` / `lng`, and missing
  `name` each return nil.

The package count rises from 136 by these cases. Existing suites are unaffected; nothing
in the package depends on `AppRouter` or the views.

The app target has no test target, so the navigation flows are verified on the iPhone 17
/ iOS 26 simulator, through the accessibility tree per the text-before-pixels rule:

- Home to preview and back, watching that the map does not flash or rebuild on the back
  step.
- Preview to navigate, End ride, summary, dismiss, and a return to the home dashboard.
- A free ride start to summary to home.
- Each deep link with `xcrun simctl openurl booted "aura://…"`: `plan`, `history`,
  `settings`, `ride`, and a `preview` with coordinates, plus a malformed URL that should
  do nothing.
- The back-swipe: a swipe pops a pre-start HUD, and a swipe during recording does not.

If a pixel capture is needed and its md5 matches the prior frame, reboot the simulator
before trusting it, per the known screenshot-freeze gotcha.

## Risks and mitigations

- **The live ride flow regresses.** The rewire touches both HUDs and the summary return
  path, which the package tests do not cover end to end. Mitigation: the simulator smoke
  test drives both flows to the summary and back before the PR.
- **The swipe-suppression bridge is fragile.** Reaching the `UINavigationController` is
  introspection that a future SwiftUI release could move. Mitigation: it is one small,
  named modifier, and the smoke test checks both the recording and pre-start states. If
  the bridge ever returns nil for the controller, the gesture simply stays at its default,
  which fails safe toward the system behavior rather than crashing.
- **The map still rebuilds on a transition.** If view identity is not stable across a
  push, the retention claim does not hold. Mitigation: the smoke test watches a back
  navigation for a rebuild, and each screen's `Map` keeps a stable position in its view.
- **A deep link lands on a wrong or crashing state.** Mitigation: the parser returns nil
  for anything unrecognized, so `handle(url:)` no-ops; the recognized set is small and
  each case is covered by a parse test and a simulator open-url check.

## Out of scope

- A single hoisted Mapbox map shared across the flow. Recorded as a fast-follow.
- Universal (https) links, Associated Domains, and an apple-app-site-association file.
- Group ride, any new screen, and any change to HUD or screen visuals. `AuraTheme` is
  reused as is.
- State restoration through `NSUserActivity` or scene storage. The `Codable` models make
  the path restoration-ready, but wiring restoration is later work.
- App-target tests. The app target still has no test target; the new tests live in the
  package.

## Rough task order

1. `AppRoute` and its tests.
2. `DeepLink` and its parser tests.
3. `AppRouter`: drop `Screen`, add `path`, the push/pop helpers, and `handle(url:)`.
4. `RootView` rewrite (tab shell, `NavigationStack`, `navigationDestination`), the
   `.onOpenURL` hook, and the `CFBundleURLTypes` entry in Info.plist.
5. `SwipeBackGesture` modifier, then the full-screen chrome on `RoutePreviewView` and
   both HUDs.
6. Rewire the eight call sites in `PlanView`, `RoutePreviewView`, `RideHUDView`, and
   `NavigateHUDView` onto the path helpers.
7. `docs/ROADMAP.md`: mark navigation shipped and Wave 1 complete.

Commits follow the repo conventions: `feat(core)` / `refactor(core)` for the package,
`refactor(app)` for the app, staging only the files each task names, never
`AuraCore/Package.resolved` or the generated `Aura.xcodeproj`. App-target file adds run
`xcodegen generate` so the new file is in the project. The branch ships through a PR into
`main` like #3 through #6, after CI is green, with a reconcile of local `main` to
`origin/main`.
