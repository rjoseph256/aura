# Navigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `AppRouter.screen` enum and the `switch` in `RootView` with a `NavigationStack(path:)` over a typed `AppRoute` enum and one `.navigationDestination`, add a guarded `handle(url:)` deep-link seam, and end the per-transition Mapbox map teardown.

**Architecture:** The `TabView` stays at the root. The Ride tab becomes a `NavigationStack(path: $router.path)` rooted at `PlanView`, with one `.navigationDestination(for: AppRoute.self)` that pushes the preview and the two ride HUDs. `AppRouter` (`@MainActor @Observable`) owns the path and a `handle(url:)` that a pure `DeepLink` parser in AuraCore feeds. A push retains the screen beneath it, so the per-transition map teardown stops. Pushed destinations hide the nav and tab bars; an active recording ride suppresses the back-swipe through a small `UINavigationController`-backed modifier, and a deep link arriving mid-ride is ignored.

**Tech Stack:** Swift 6 / Xcode 26, SwiftUI, the local `AuraCore` SwiftPM package (`AuraCore` + `AuraKit`), Mapbox (app target only), Swift Testing for the new package suites, XcodeGen, SwiftLint 0.64.1.

**Spec:** `docs/superpowers/specs/2026-06-26-aura-wave-1-navigation-design.md`

## Global Constraints

- Swift 6 language mode is on across all targets. Deployment target is iOS 17; the simulator is iPhone 17 / iOS 26.
- New AuraCore types must compile on the macOS CI host (no UIKit/SwiftUI in the package). `AppRoute` and `DeepLink` are pure and meet this on their own.
- SwiftLint is pinned to 0.64.1 and runs `--strict` over the whole repo. Lint the whole package, not only changed files (`./scripts/lint.sh` from the repo root).
- Commit messages end with the trailer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Never `git add AuraCore/Package.resolved` (if a build dirties it, `git checkout -- AuraCore/Package.resolved`). Never commit `Aura/Aura.xcodeproj` (generated) or `Aura/Resources/MapboxAccessToken` (gitignored). Stage only the files each task names.
- Adding or deleting a file under the **app** target (`Aura/Sources/**`) requires `cd Aura && xcodegen generate` so the generated project picks it up. Files under `AuraCore/Sources/**` are auto-globbed by SwiftPM and need no regeneration. Only Task 5 adds an app-target file.

## Conventions for every task

- **Builds and tests are delegated** to the `apple-platform-build-tools:builder` subagent so the verbose logs stay out of context. Hand it the exact command and act on its pass/fail summary.
- **Package tests:** `cd AuraCore && swift test` (optionally `--filter AppRouteTests` or `--filter DeepLinkTests` while iterating). Runs on the macOS host under Swift 6.
- **App build:** `cd Aura && xcodebuild build -project Aura.xcodeproj -scheme Aura -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`. This compiles the app and the embedded `AuraWidgets`. If it reports a missing `MapboxAccessToken`, copy the `pk.…` token from the primary checkout into `Aura/Resources/MapboxAccessToken` and rebuild.
- **Lint:** `./scripts/lint.sh` from the repo root.
- **Simulator smoke** verifies through the accessibility tree (`ui_describe_all`) per the text-before-pixels rule. If a pixel capture is needed and its md5 matches the prior frame, reboot the simulator first. Install the build the builder just produced (newest mtime), not whatever `find` returns first.
- **Keep green:** the package tests, the app build, and lint pass at the end of every task that touches their inputs.

## File structure

**Created (package, `AuraCore/Sources/AuraCore/Navigation/`):**
- `AppRoute.swift`: the typed path element; manual id-keyed `Equatable`/`Hashable`.
- `DeepLink.swift`: the deep-link intent enum and the pure `aura://` parser.

**Created (package tests, `AuraCore/Tests/AuraCoreTests/`):**
- `AppRouteTests.swift`: identity tests.
- `DeepLinkTests.swift`: parser tests.

**Created (app target):**
- `Aura/Sources/App/SwipeBackGesture.swift`: the `.swipeBackEnabled(_:)` modifier (Task 5).

**Modified (app target):**
- `Aura/Sources/App/AppRouter.swift`: path, helpers, `isRideActive`, `handle(url:)`; `Screen` removed in Task 4.
- `Aura/Sources/AuraApp.swift`: `RootView` becomes the tab shell with the `NavigationStack`; `AuraTabView` folds in; `.onOpenURL` added.
- `Aura/Sources/Plan/PlanView.swift`, `Aura/Sources/Plan/RoutePreviewView.swift`, `Aura/Sources/Ride/RideHUDView.swift`, `Aura/Sources/Ride/NavigateHUDView.swift`: call-site rewires and (Task 5) full-screen chrome.
- `Aura/Resources/Info.plist`: `CFBundleURLTypes` with the `aura` scheme.
- `docs/ROADMAP.md`: mark navigation shipped and Wave 1 complete.

---

## Task 1: `AppRoute` typed path element

The pure enum that the `NavigationStack` path holds. Identity is the case plus the stable ids, so hashing never touches a route's geometry.

**Files:**
- Create: `AuraCore/Sources/AuraCore/Navigation/AppRoute.swift`
- Test: `AuraCore/Tests/AuraCoreTests/AppRouteTests.swift`

**Interfaces:**
- Produces: `public enum AppRoute: Hashable, Sendable { case freeRide; case preview(Place); case navigate(route: Route, destination: Place?) }`.

- [ ] **Step 1: Write the failing tests**

Create `AuraCore/Tests/AuraCoreTests/AppRouteTests.swift`:

```swift
import Testing
import Foundation
import AuraCore

@Suite struct AppRouteTests {
    private func place(_ id: UUID = UUID(), _ name: String = "Dest") -> Place {
        Place(id: id, name: name, coordinate: Coordinate(latitude: 40.44, longitude: -79.99),
              category: .custom)
    }

    private func route(_ id: UUID = UUID(), geometryCount: Int = 2) -> Route {
        Route(id: id, origin: Coordinate(latitude: 40.44, longitude: -79.99),
              destination: Coordinate(latitude: 40.46, longitude: -79.92), waypoints: [],
              geometry: Array(repeating: Coordinate(latitude: 40.44, longitude: -79.99),
                              count: geometryCount),
              profile: .fastest, distanceMeters: 1000, estimatedDurationSeconds: 300,
              elevationGainMeters: 10)
    }

    @Test func freeRideEqualsItself() {
        #expect(AppRoute.freeRide == AppRoute.freeRide)
        #expect(AppRoute.freeRide.hashValue == AppRoute.freeRide.hashValue)
    }

    @Test func previewEqualByPlaceId() {
        let id = UUID()
        #expect(AppRoute.preview(place(id, "A")) == AppRoute.preview(place(id, "B")))
        #expect(AppRoute.preview(place()) != AppRoute.preview(place()))
    }

    @Test func navigateEqualByRouteAndDestinationId() {
        let r = UUID(); let d = UUID()
        #expect(AppRoute.navigate(route: route(r), destination: place(d))
                == AppRoute.navigate(route: route(r), destination: place(d)))
        // Same route id, different destination id -> not equal.
        #expect(AppRoute.navigate(route: route(r), destination: place(d))
                != AppRoute.navigate(route: route(r), destination: place()))
        // Different route id, same destination id -> not equal.
        #expect(AppRoute.navigate(route: route(), destination: place(d))
                != AppRoute.navigate(route: route(), destination: place(d)))
    }

    @Test func navigateIdentityIgnoresGeometry() {
        let r = UUID()
        let small = AppRoute.navigate(route: route(r, geometryCount: 2), destination: nil)
        let large = AppRoute.navigate(route: route(r, geometryCount: 5000), destination: nil)
        #expect(small == large)
        #expect(small.hashValue == large.hashValue)
    }

    @Test func differentCasesAreUnequal() {
        #expect(AppRoute.freeRide != AppRoute.preview(place()))
        #expect(AppRoute.preview(place()) != AppRoute.navigate(route: route(), destination: nil))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Delegate to the builder: `cd AuraCore && swift test --filter AppRouteTests`
Expected: FAIL with `cannot find 'AppRoute' in scope`.

- [ ] **Step 3: Create `AppRoute`**

Create `AuraCore/Sources/AuraCore/Navigation/AppRoute.swift`:

```swift
import Foundation

/// A destination on the Ride tab's navigation stack. Held by `NavigationStack(path:)`.
///
/// `Equatable` and `Hashable` are written by hand against the stable ids of the payloads,
/// not their contents, so the path stays cheap to hash and a `Route`'s geometry is never
/// hashed. Two values with the same case and the same ids are the same navigation entry.
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

- [ ] **Step 4: Run the tests to verify they pass**

Delegate to the builder: `cd AuraCore && swift test --filter AppRouteTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Full package test run**

Delegate to the builder: `cd AuraCore && swift test`
Expected: PASS, all existing tests plus the 6 new ones.

- [ ] **Step 6: Commit**

```bash
git add AuraCore/Sources/AuraCore/Navigation/AppRoute.swift \
        AuraCore/Tests/AuraCoreTests/AppRouteTests.swift
git commit -m "feat(core): add AppRoute typed navigation path element

A pure enum (freeRide / preview / navigate) for the Ride tab's NavigationStack
path, with manual Equatable+Hashable keyed on place.id and route.id so the path
never hashes a route's geometry and the core models gain no conformance.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `DeepLink` and the `aura://` parser

The pure URL-to-intent parser. It is the part of deep linking with the bugs, so it lives in AuraCore under test.

**Files:**
- Create: `AuraCore/Sources/AuraCore/Navigation/DeepLink.swift`
- Test: `AuraCore/Tests/AuraCoreTests/DeepLinkTests.swift`

**Interfaces:**
- Produces: `public enum DeepLink: Equatable, Sendable { case home; case history; case settings; case freeRide; case preview(Place) }` and `public static func parse(_ url: URL) -> DeepLink?`.

- [ ] **Step 1: Write the failing tests**

Create `AuraCore/Tests/AuraCoreTests/DeepLinkTests.swift`:

```swift
import Testing
import Foundation
import AuraCore

@Suite struct DeepLinkTests {
    private func parse(_ string: String) -> DeepLink? {
        DeepLink.parse(URL(string: string)!)
    }

    @Test func parsesTabAndRideHosts() {
        #expect(parse("aura://plan") == .home)
        #expect(parse("aura://history") == .history)
        #expect(parse("aura://settings") == .settings)
        #expect(parse("aura://ride") == .freeRide)
    }

    @Test func parsesPreviewIntoPlace() {
        guard case let .preview(place)? =
                parse("aura://preview?lat=40.44&lng=-79.99&name=Church%20Brew%20Works") else {
            Issue.record("expected .preview"); return
        }
        #expect(place.name == "Church Brew Works")
        #expect(place.coordinate.latitude == 40.44)
        #expect(place.coordinate.longitude == -79.99)
        #expect(place.category == .custom)
        #expect(place.isSaved == false)
    }

    @Test func previewMintsFreshIdEachParse() {
        let url = "aura://preview?lat=1&lng=2&name=A"
        guard case let .preview(a)? = parse(url), case let .preview(b)? = parse(url) else {
            Issue.record("expected two .preview"); return
        }
        #expect(a.id != b.id)
    }

    @Test func rejectsBadInput() {
        #expect(parse("aura://nope") == nil)                         // unknown host
        #expect(parse("https://preview?lat=1&lng=2&name=A") == nil)  // wrong scheme
        #expect(parse("aura://preview?lng=2&name=A") == nil)         // missing lat
        #expect(parse("aura://preview?lat=abc&lng=2&name=A") == nil) // non-numeric lat
        #expect(parse("aura://preview?lat=1&lng=2") == nil)          // missing name
        #expect(parse("aura://preview?lat=1&lng=2&name=") == nil)    // empty name
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Delegate to the builder: `cd AuraCore && swift test --filter DeepLinkTests`
Expected: FAIL with `cannot find 'DeepLink' in scope`.

- [ ] **Step 3: Create `DeepLink`**

Create `AuraCore/Sources/AuraCore/Navigation/DeepLink.swift`:

```swift
import Foundation

/// A parsed deep-link intent. Separate from `AppRoute` because `home`, `history`, and
/// `settings` select a tab rather than push a route, so this is not a subset of the path
/// element. The app maps an intent onto `selectedTab` and the path in `AppRouter.handle(url:)`.
public enum DeepLink: Equatable, Sendable {
    case home          // Ride tab, pop to root
    case history
    case settings
    case freeRide      // Ride tab, pre-start free-ride HUD
    case preview(Place)

    /// Parses an `aura://…` URL. Returns nil for any scheme, host, or parameter set the app
    /// does not recognize, so an unknown link is a no-op rather than a guess.
    public static func parse(_ url: URL) -> DeepLink? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "aura" else { return nil }
        // Custom-scheme URLs carry the route in the host (aura://plan). Fall back to a
        // slash-trimmed path for the rare opaque form.
        let host = components.host ?? components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch host {
        case "plan":     return .home
        case "history":  return .history
        case "settings": return .settings
        case "ride":     return .freeRide
        case "preview":  return preview(from: components)
        default:         return nil
        }
    }

    private static func preview(from components: URLComponents) -> DeepLink? {
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        guard let latText = value("lat"), let lat = Double(latText),
              let lngText = value("lng"), let lng = Double(lngText),
              let name = value("name"), !name.isEmpty else {
            return nil
        }
        let place = Place(name: name,
                          coordinate: Coordinate(latitude: lat, longitude: lng),
                          category: .custom)
        return .preview(place)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Delegate to the builder: `cd AuraCore && swift test --filter DeepLinkTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Full package test run + lint**

Delegate to the builder: `cd AuraCore && swift test` (all green) and `./scripts/lint.sh` (0 violations).

- [ ] **Step 6: Commit**

```bash
git add AuraCore/Sources/AuraCore/Navigation/DeepLink.swift \
        AuraCore/Tests/AuraCoreTests/DeepLinkTests.swift
git commit -m "feat(core): add DeepLink intent and the aura:// parser

A pure URL-to-intent parser (home/history/settings/freeRide/preview) in AuraCore,
unit-tested on the CI host. Unknown scheme, host, or query returns nil so an
unrecognized link is a no-op.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: `AppRouter` path API (additive)

Add the path, its helpers, the recording flag, and the guarded `handle(url:)`. `Screen` and `screen` stay for now so the app still builds; Task 4 removes them with their consumers.

**Files:**
- Modify: `Aura/Sources/App/AppRouter.swift`

**Interfaces:**
- Consumes: `AppRoute` (Task 1), `DeepLink` (Task 2).
- Produces: `var path: [AppRoute]`, `var isRideActive: Bool`, `func push(_:)`, `func pop()`, `func popToRoot()`, `func handle(url:)`.

- [ ] **Step 1: Add the path API**

In `Aura/Sources/App/AppRouter.swift`, the file already has `import AuraCore`. Add the following members inside the `AppRouter` class, right after the `var selectedTab: Tab = .ride` line:

```swift
    /// The Ride tab's navigation stack, bound by the NavigationStack in RootView.
    var path: [AppRoute] = []

    /// True while a ride HUD is recording. The HUDs drive it from `coordinator.isRecording`;
    /// `handle(url:)` reads it so a deep link cannot pop an active ride out from under the rider.
    var isRideActive = false

    func push(_ route: AppRoute) { path.append(route) }
    func pop() { if !path.isEmpty { path.removeLast() } }
    func popToRoot() { path.removeAll() }

    /// Routes an `aura://…` deep link to the tab and path. A recording ride takes precedence:
    /// a URL must never abandon it, so every link is dropped while `isRideActive`. Unknown
    /// links are dropped too, because the parser returns nil for them.
    func handle(url: URL) {
        guard !isRideActive, let link = DeepLink.parse(url) else { return }
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

Leave `Screen`, `var screen`, `recents`, `remember`, and the `UserDefaults` wiring exactly as they are.

- [ ] **Step 2: Build the app**

Delegate to the builder: `cd Aura && xcodebuild build -project Aura.xcodeproj -scheme Aura -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED. (`Screen` is still present and used by `RootView`; the new members are unused for now, which is fine.)

- [ ] **Step 3: Lint**

Delegate to the builder: `./scripts/lint.sh`
Expected: 0 violations.

- [ ] **Step 4: Commit**

```bash
git add Aura/Sources/App/AppRouter.swift
git commit -m "feat(app): add NavigationStack path API to AppRouter

Adds path, push/pop/popToRoot, an isRideActive flag, and a guarded handle(url:)
that maps a parsed DeepLink onto the tab and path. Additive: Screen stays until
RootView and the call sites move onto the path in the next commit.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Switch `RootView` to the stack and rewire every call site

The atomic structural switch. `RootView` becomes the tab shell with the `NavigationStack`; `AuraTabView` and `AppRouter.Screen` are removed; all nine `router.screen` writes move to path helpers; both HUDs bind `isRideActive`; `.onOpenURL` and the URL scheme are wired. Everything that references `Screen` changes together, so the app builds again only at the end of this task. Full-screen chrome and swipe suppression are layered on in Task 5; navigation is functional after this task with the system nav and tab bars still visible on the pushed screens.

**Files:**
- Modify: `Aura/Sources/AuraApp.swift`, `Aura/Sources/App/AppRouter.swift`, `Aura/Sources/Plan/PlanView.swift`, `Aura/Sources/Plan/RoutePreviewView.swift`, `Aura/Sources/Ride/RideHUDView.swift`, `Aura/Sources/Ride/NavigateHUDView.swift`, `Aura/Resources/Info.plist`

- [ ] **Step 1: Remove `Screen` from `AppRouter`**

In `Aura/Sources/App/AppRouter.swift`, delete the `Screen` enum and the `var screen` property:

```swift
    enum Screen: Equatable {
        case plan
        case preview(destination: Place)
        case ride(route: Route?, destination: Place?)   // nil route => free ride
    }
    var screen: Screen = .plan
```

Keep `Tab`, `selectedTab`, `path`, the helpers, `handle(url:)`, `recents`, and `remember`. Update the `selectedTab` doc comment that mentions `AuraTabView` to say "the Ride tab's NavigationStack" instead.

- [ ] **Step 2: Rewrite `RootView` and fold in `AuraTabView`**

Replace the `RootView` and `AuraTabView` sections of `Aura/Sources/AuraApp.swift` (everything from `// MARK: - RootView` to the end of the file) with:

```swift
// MARK: - RootView

/// The app's tab shell. The Ride tab is a NavigationStack whose path the AppRouter owns;
/// History and Settings keep their own stacks. Pushing preview or a ride HUD retains the
/// screen beneath it, so transitions no longer tear down and rebuild the Mapbox map.
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

This removes the `switch`, the `.animation(value: router.screen)` cross-fade (push/pop uses the system transition), and the `AuraTabView` type.

- [ ] **Step 3: Add the deep-link hook in `AuraApp.body`**

In `Aura/Sources/AuraApp.swift`, add `.onOpenURL` to the `RootView()` in the `WindowGroup`, after the existing `.preferredColorScheme(.dark)`:

```swift
            RootView()
                .environment(router)
                .environment(rideStore)
                .environment(settings)
                .environment(location)
                .preferredColorScheme(.dark)
                .onOpenURL { router.handle(url: $0) }
```

- [ ] **Step 4: Register the `aura` URL scheme in Info.plist**

In `Aura/Resources/Info.plist`, add this entry inside the top-level `<dict>` (for example right after the `UIApplicationSceneManifest` block):

```xml
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>app.aura.ios</string>
      <key>CFBundleURLSchemes</key>
      <array><string>aura</string></array>
    </dict>
  </array>
```

- [ ] **Step 5: Rewire `PlanView`**

In `Aura/Sources/Plan/PlanView.swift`:

The search handler (inside `DestinationSearchView(query: $query) { place in … }`):
```swift
                DestinationSearchView(query: $query) { place in
                    router.remember(place)
                    router.push(.preview(place))
                }
```
The recents row handler (inside `RecentRow(place: place) { … }`):
```swift
                    RecentRow(place: place) {
                        router.push(.preview(place))
                    }
```
The free-ride button:
```swift
        Button("Free ride") {
            router.push(.freeRide)
        }
```

- [ ] **Step 6: Rewire `RoutePreviewView`**

In `Aura/Sources/Plan/RoutePreviewView.swift`, three sites:

The map-pane back chevron (`mapPane`):
```swift
            Button {
                router.pop()
            } label: {
                Image(systemName: "chevron.left")
            }
```
The empty/failed `backButton`:
```swift
    private var backButton: some View {
        Button {
            router.pop()
        } label: {
```
The Start CTA (guard the optional `selected`):
```swift
    private var startButton: some View {
        Button("Start RIDE") {
            if let selected {
                router.push(.navigate(route: selected, destination: destination))
            }
        }
        .buttonStyle(.ctaPrimary)
        .disabled(selected == nil)
        .animation(.easeOut(duration: 0.18), value: selected?.id)
    }
```

- [ ] **Step 7: Rewire `RideHUDView` and bind `isRideActive`**

In `Aura/Sources/Ride/RideHUDView.swift`:

The summary sheet `onDismiss`:
```swift
        .sheet(item: $coordinator.finishedRide, onDismiss: { router.popToRoot() }, content: { ride in
            RideSummaryView(ride: ride, saveFailed: coordinator.saveFailed)
        })
```
The pre-start back button:
```swift
    private var backButton: some View {
        Button {
            router.popToRoot()
        } label: {
            Image(systemName: "chevron.left")
        }
        .buttonStyle(.hudControl)
        .accessibilityLabel("Back to home")
    }
```
Replace the existing `.onDisappear { coordinator.cancel() }` with a recording binding plus the cancel:
```swift
        .onChange(of: coordinator.isRecording) { _, recording in
            router.isRideActive = recording
        }
        .onDisappear {
            router.isRideActive = false
            coordinator.cancel()
        }
```

- [ ] **Step 8: Rewire `NavigateHUDView` and bind `isRideActive`**

In `Aura/Sources/Ride/NavigateHUDView.swift`:

The summary sheet `onDismiss`:
```swift
        .sheet(item: $coordinator.finishedRide, onDismiss: {
            router.popToRoot()
        }, content: { ride in
            RideSummaryView(ride: ride, saveFailed: coordinator.saveFailed)
        })
```
Replace the existing `.onDisappear { teardownGuidance(); coordinator.cancel() }` with the recording binding plus the existing teardown:
```swift
        .onChange(of: coordinator.isRecording) { _, recording in
            router.isRideActive = recording
        }
        .onDisappear {
            router.isRideActive = false
            teardownGuidance()
            coordinator.cancel()
        }
```

- [ ] **Step 9: Build the app**

Delegate to the builder: `cd Aura && xcodebuild build -project Aura.xcodeproj -scheme Aura -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED. No `xcodegen generate` is needed: no app-target file was added or deleted (Info.plist is edited in place, not added). If the build reports an unresolved `Screen` or `AuraTabView`, a call site was missed; grep `git grep -n "router.screen\|AuraTabView\|\.screen ="` under `Aura/Sources` and fix it.

- [ ] **Step 10: Lint**

Delegate to the builder: `./scripts/lint.sh`
Expected: 0 violations.

- [ ] **Step 11: Simulator smoke (navigation works)**

Delegate to the builder / ios-simulator tools: install and launch the just-built app on the booted iPhone 17 / iOS 26 sim. Through the accessibility tree:
- Tabs switch (Ride / History / Settings).
- Search or tap a recent to push preview; the back control returns to the dashboard.
- Free ride: push the HUD, Start, End ride, summary, dismiss, land back on the dashboard.
- Plan a route, Start RIDE, reach the navigate HUD, End ride, summary, dismiss, land on the dashboard.
- Deep links: `xcrun simctl openurl booted "aura://history"` (switches tab), `"aura://preview?lat=40.44&lng=-79.99&name=Test"` (opens preview), and `"aura://bogus"` (no change).
- Mid-ride guard: start a free ride recording, run `xcrun simctl openurl booted "aura://plan"`, and confirm the ride is still recording (not abandoned).

The pushed preview/HUD still show the nav and tab bars at this point; Task 5 makes them full-bleed.

- [ ] **Step 12: Commit**

```bash
git add Aura/Sources/AuraApp.swift Aura/Sources/App/AppRouter.swift \
        Aura/Sources/Plan/PlanView.swift Aura/Sources/Plan/RoutePreviewView.swift \
        Aura/Sources/Ride/RideHUDView.swift Aura/Sources/Ride/NavigateHUDView.swift \
        Aura/Resources/Info.plist
git commit -m "refactor(app): drive navigation through NavigationStack and a typed path

RootView becomes the tab shell with the Ride tab's NavigationStack and one
navigationDestination; AuraTabView and AppRouter.Screen are removed; all nine
router.screen writes move to push/pop/popToRoot; both HUDs bind isRideActive from
coordinator.isRecording; onOpenURL routes aura:// links through handle(url:), with
the scheme registered in Info.plist. Pushing now retains the map under a transition.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Full-screen chrome and back-swipe suppression

Layer the full-bleed presentation and the back-gesture rules onto the working stack. One small `UINavigationController`-backed modifier both re-asserts the swipe under a hidden bar (preview) and suppresses it while recording (the HUDs).

**Files:**
- Create: `Aura/Sources/App/SwipeBackGesture.swift`
- Modify: `Aura/Sources/Plan/RoutePreviewView.swift`, `Aura/Sources/Ride/RideHUDView.swift`, `Aura/Sources/Ride/NavigateHUDView.swift`

**Interfaces:**
- Produces: `func swipeBackEnabled(_ enabled: Bool) -> some View` on `View`.

- [ ] **Step 1: Create the swipe-back modifier**

Create `Aura/Sources/App/SwipeBackGesture.swift`:

```swift
import SwiftUI
import UIKit

extension View {
    /// Enables or disables the enclosing NavigationStack's interactive pop (edge swipe) for
    /// the screen it is attached to. Used to re-assert the swipe under a hidden navigation
    /// bar, and to stop an actively recording ride from being swiped away by accident.
    func swipeBackEnabled(_ enabled: Bool) -> some View {
        background(SwipeBackGestureToggle(enabled: enabled))
    }
}

/// Reaches the hosting UINavigationController and toggles its interactive-pop gesture. It is
/// the one piece of UIKit introspection in navigation; if the controller can't be found the
/// gesture stays at the system default, which fails safe rather than crashing. Everything
/// runs in synchronous main-actor contexts (updateUIViewController and didMove are
/// @MainActor), so there is no Sendable capture to trip Swift 6 strict concurrency.
private struct SwipeBackGestureToggle: UIViewControllerRepresentable {
    let enabled: Bool

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.desiredEnabled = enabled
        controller.applyToNavigationController()
    }

    final class Controller: UIViewController {
        var desiredEnabled = true

        // didMove fires once the controller is in the hierarchy, when the parent
        // navigation controller is resolvable; updateUIViewController re-applies on changes.
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            applyToNavigationController()
        }

        func applyToNavigationController() {
            navigationController?.interactivePopGestureRecognizer?.isEnabled = desiredEnabled
        }
    }
}
```

- [ ] **Step 2: Regenerate the Xcode project (new app-target file)**

Delegate to the builder: `cd Aura && xcodegen generate`
This adds `SwipeBackGesture.swift` to the generated project. Do not commit `Aura/Aura.xcodeproj`.

- [ ] **Step 3: Full-screen chrome on `RoutePreviewView`**

In `Aura/Sources/Plan/RoutePreviewView.swift`, attach the modifiers to the outer `ZStack` of `body`, right after the existing `.onChange(of: selected) { … }` block (before the closing brace of `body`):

```swift
        .onChange(of: selected) { _, newRoute in
            if let route = newRoute {
                fitCamera(to: route, animate: !reduceMotion)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .navigationBarBackButtonHidden(true)
        .swipeBackEnabled(true)
```

Preview keeps its in-content back chevron; `swipeBackEnabled(true)` re-asserts the edge swipe under the hidden bar.

- [ ] **Step 4: Full-screen chrome on `RideHUDView`**

In `Aura/Sources/Ride/RideHUDView.swift`, attach the modifiers to the outer `ZStack` of `body`, right after the `.onChange(of: coordinator.isRecording)` / `.onDisappear` block added in Task 4:

```swift
        .onChange(of: coordinator.isRecording) { _, recording in
            router.isRideActive = recording
        }
        .onDisappear {
            router.isRideActive = false
            coordinator.cancel()
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .navigationBarBackButtonHidden(true)
        .swipeBackEnabled(!coordinator.isRecording)
```

Before recording, the swipe and the pre-start back button both work; once recording, the swipe is gone.

- [ ] **Step 5: Full-screen chrome on `NavigateHUDView`**

In `Aura/Sources/Ride/NavigateHUDView.swift`, attach the modifiers to the outer `ZStack` of `body`, right after the `.onChange(of: coordinator.isRecording)` / `.onDisappear` block added in Task 4:

```swift
        .onChange(of: coordinator.isRecording) { _, recording in
            router.isRideActive = recording
        }
        .onDisappear {
            router.isRideActive = false
            teardownGuidance()
            coordinator.cancel()
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .navigationBarBackButtonHidden(true)
        .swipeBackEnabled(false)
```

Navigate suppresses the swipe for its whole lifetime: it has no pre-start back state, the rider exits through End ride or arrival, and a constant `false` closes the window between push and `start()`.

- [ ] **Step 6: Build the app**

Delegate to the builder: `cd Aura && xcodebuild build -project Aura.xcodeproj -scheme Aura -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Lint**

Delegate to the builder: `./scripts/lint.sh`
Expected: 0 violations.

- [ ] **Step 8: Simulator smoke (full-screen and swipe)**

Delegate to the builder / ios-simulator tools, on the just-built app:
- Preview, free ride, and navigate are full-bleed with no nav bar and no tab bar.
- Preview: a back-swipe pops to the dashboard (the swipe still works under the hidden bar); the in-content back chevron also works.
- Free ride: a back-swipe before tapping Start pops to the dashboard; after Start (recording), a back-swipe does NOT pop; End ride, summary, dismiss, land on the dashboard. Run End-ride to dashboard twice and confirm no stuck dim layer.
- Navigate: a back-swipe does not pop; End ride / arrival returns through the summary.
- Re-confirm the mid-ride deep-link guard: while recording, `xcrun simctl openurl booted "aura://ride"` does not abandon the ride.
- Confirm the map does not flash or rebuild stepping preview to navigate and back.

- [ ] **Step 9: Commit**

```bash
git add Aura/Sources/App/SwipeBackGesture.swift \
        Aura/Sources/Plan/RoutePreviewView.swift \
        Aura/Sources/Ride/RideHUDView.swift \
        Aura/Sources/Ride/NavigateHUDView.swift
git commit -m "refactor(app): full-screen chrome and recording-aware back-swipe

Pushed preview and ride HUDs hide the nav and tab bars. A small
UINavigationController-backed swipeBackEnabled modifier re-asserts the edge swipe
for preview under the hidden bar, leaves it on for a pre-start free ride, and
suppresses it while recording so a stray swipe can't abandon a ride.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: ROADMAP update and final verification

**Files:**
- Modify: `docs/ROADMAP.md`

- [ ] **Step 1: Mark navigation shipped and Wave 1 complete**

In `docs/ROADMAP.md`, under "Wave 1 — Structural foundations", replace the **Navigation** bullet with a SHIPPED entry (dated 2026-06-26) stating: the `AppRouter.screen` switch is replaced by a `NavigationStack(path:)` over a typed `AppRoute` enum in AuraCore (manual id-keyed `Hashable`, so the path never hashes a route's geometry) and one `.navigationDestination`; `AppRouter` owns the path and a `handle(url:)` that a pure, CI-tested `DeepLink` parser feeds over the `aura://` scheme; pushing retains the Mapbox map across a transition instead of rebuilding it; pushed screens are full-bleed and an actively recording ride suppresses the back-swipe; a deep link arriving mid-ride is ignored so it cannot abandon the ride. Note the AuraCore tests for `AppRoute` and `DeepLink`, and that a single hoisted shared map remains a documented fast-follow. Also update the audit-finding paragraph that calls navigation "the largest rebuild item" to note it is resolved, and any "remaining Wave 1 sub-project is navigation" or sub-project-count phrasing to state Wave 1 is complete. Keep the prose plain and free of em dashes per the writing convention.

- [ ] **Step 2: Full verification sweep**

Delegate to the builder:
- `cd AuraCore && swift test`: all green, including the new `AppRouteTests` and `DeepLinkTests`.
- `cd Aura && xcodebuild build -project Aura.xcodeproj -scheme Aura -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`: BUILD SUCCEEDED (app + AuraWidgets).
- `./scripts/lint.sh`: 0 violations over the whole repo.

- [ ] **Step 3: Commit**

```bash
git add docs/ROADMAP.md
git commit -m "docs(roadmap): mark navigation shipped and Wave 1 complete

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Done criteria

- The `AppRouter.screen` enum and the `RootView` switch are gone. Navigation runs through `NavigationStack(path: $router.path)` over `AppRoute` with one `.navigationDestination`, and `AppRouter` owns `path` plus `handle(url:)`.
- `AppRoute` and `DeepLink` live in AuraCore with passing Swift Testing suites that run on the macOS CI host; the whole package suite is green.
- The `aura://` scheme is registered and `.onOpenURL` routes through the guarded `handle(url:)`; a deep link never abandons a recording ride.
- Pushed preview and ride HUDs are full-bleed; preview keeps its back-swipe, and an actively recording ride does not; the Mapbox map is retained across a push.
- The app and `AuraWidgets` build, SwiftLint is clean over the whole repo, and the navigation, deep-link, and back-swipe flows are verified on the simulator.
- `docs/ROADMAP.md` marks navigation shipped and Wave 1 complete.
- The branch is ready to ship through a PR into `main` like #3 through #6 (the finishing-a-development-branch step handles the PR, CI wait, merge, and local reconcile, after asking first).
```