# AuraUITests: on-device and simulator UI regression net

Status: approved design, 2026-07-01.

The app layer has no automated tests. All 226-plus tests live below the app boundary in
the `AuraCore` package; CI builds the app but never launches it, so a broken tab, a
mis-wired toggle, or a screen that fails to present passes green. This adds an XCUITest
bundle that launches the real app and drives the deterministic flows, closing that gap for
the parts that need no movement, GPS, authorization, network, or a second device.

## Scope

In scope, because each is deterministic and self-contained:

- Launch reaches the home dashboard and the tab bar shows Ride, History, and Settings.
- History tab presents its list or its empty state.
- Settings tab presents its rows, and the controls are wired: the "Turn haptics" switch
  reads a value and flips it, the weekly-goal stepper increments, and the "Save rides to
  Health" switch is present with a real boolean state (it is not flipped, because turning
  it on shows the HealthKit authorization sheet).
- The group-ride join screen is reachable from "Join a ride": the sheet presents and
  cancels, without actually joining a ride.

Deferred within this pass (documented, not silent):

- The distance-units control is a `.menu`-style `Picker`; driving its menu is flakier than
  the plain toggles and stepper, so a units-change test is left for a follow-up.
- Typing into the join code field is not UI-tested. `GroupRideJoinView` deliberately hides
  the raw `TextField` from accessibility and composes a custom VoiceOver element over the
  code boxes, so there is no text-field locator to type into without changing that
  accessibility design. Code entry stays in the on-device pass.
- The free-ride pre-start screen: its entry point was not confirmable on the home
  dashboard during design, so a locator would be a guess.
- The free-ride pre-start screen is reachable from the Ride tab.

Out of scope, because they need a sensor, an account, a network peer, or a second device
(these stay in the human pass in `docs/DEVICE-TESTING.md`): starting a real recording,
HealthKit workout content, live group-ride peers, iCloud sync, the Live Activity, and
widgets.

## Target and wiring

A new `AuraUITests` target of type `bundle.ui-testing`, hosted by the `Aura` app, added to
`Aura/project.yml`. Because XcodeGen auto-generates schemes, the `Aura` scheme's test
action must include `AuraUITests` so `xcodebuild test -scheme Aura` runs it; add an
explicit `schemes:` entry for `Aura` if the auto-wiring does not pick it up. The target
depends on nothing but XCTest and the running app (UI tests are black-box; they do not link
`AuraKit`).

## Test structure

Screen objects, one per screen, keep the tests readable and put each screen's locators in
one place so a UI change touches one file:

- `HomeScreen` (tab bar, "Where to?", "Join a ride")
- `SettingsScreen` (the switches, the units control, the weekly-goal stepper)
- `HistoryScreen` (list or empty state)
- `JoinRideScreen` (the code field and its validation)
- `RideScreen` (the free-ride pre-start entry)

Each screen object exposes named queries and actions (for example
`SettingsScreen.healthToggle`, `.setHealth(on:)`). Test methods read as a short sequence of
screen-object calls plus assertions. A shared `launchApp()` helper in the base test sets a
launch argument (`-uiTesting`) the app can read to keep behavior deterministic if needed
(for example, skipping a first-run animation), though the first pass avoids app changes
where the existing UI is already stable.

## Locators

Prefer stable accessibility identifiers. Most elements already expose usable names, read
live from the device: "Settings", "Save rides to Health", "Turn haptics", "Join a ride",
"Distance units". Where a control is ambiguous, localized, or identified only by a visible
label that could change (the weekly-goal stepper, the units segmented control), add an
`accessibilityIdentifier` in the app view so the test binds to a stable id rather than
display text. Keep these additions minimal and named for the control, not the test.

## Running

- Simulator (the CI-ready path): `cd Aura && xcodegen generate && xcodebuild test -project
  Aura.xcodeproj -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 17'`.
- Device (proven working this session, via the signed build and the RemoteXPC path):
  `xcodebuild test -project Aura.xcodeproj -scheme Aura -destination
  'platform=iOS,id=<device-id>' -allowProvisioningUpdates`.

The tests must pass on the simulator, which is the gate for this work. The device run is a
convenience, not a requirement, since the flows are device-agnostic.

## CI

Deferred to a fast-follow. A Mapbox-backed UI-test job is slow and prone to flake, so it
earns its own iteration once the tests prove stable locally. The follow-up adds a CI job
that runs `xcodebuild test -scheme Aura` on the simulator with the existing Mapbox token
secret. This spec does not add the job.

## Testing this work

The deliverable is tests, so the verification is running them. Each task ends by running
the new tests on the simulator and confirming they pass and the output is clean. There is
no separate test-of-the-tests.

## Rollout order

1. Add the `AuraUITests` target and scheme wiring; a single smoke test that launches the
   app and asserts the tab bar exists. Prove `xcodebuild test` runs it green on the
   simulator.
2. Add the `HomeScreen` and tab-navigation tests (History and Settings reachable).
3. Add the `SettingsScreen` object and the toggle, units, and stepper tests, adding
   accessibility identifiers in the app only where a locator is otherwise unstable.
4. Add the `JoinRideScreen` reachability and code-field test, and the `RideScreen`
   pre-start reachability test.
