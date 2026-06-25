# Wave 1 quality-gates implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the CI safety net for the rest of Wave 1: SwiftLint enforced under `--strict`, the whole codebase building under Swift 6 language mode, and the app (plus its widget extension) compiled by `xcodebuild` in CI on every pull request.

**Architecture:** Five sequential, independently verifiable change sets. Lint first (mechanical, lands the repo green), then Swift 6 in dependency order (fix the one package blocker, flip the package, then the app and widget with the executable concurrency posture), then the CI workflow that gates all of it. Every change is configuration or a behavior-preserving fix; no runtime behavior changes.

**Tech stack:** Swift 6.2 (Xcode 26.3, toolchain confirmed on this machine), Swift Package Manager (AuraCore/AuraKit), XcodeGen + xcodebuild (app), SwiftLint 0.64.1, GitHub Actions (macOS runners), Mapbox SDKs (binary, token-gated).

**Relevant skills:** @all-ios-skills:swiftlint (Task 1), @all-ios-skills:swift-concurrency (Tasks 2–4), @apple-platform-build-tools:builder (delegate the app build/verify in Task 4).

---

## Reconnaissance baseline (already gathered — do not re-derive)

Trust these findings; they were measured on this worktree:

- **Toolchain:** Swift 6.2.4, Xcode 26.3, xcodegen 2.45.4, SwiftLint 0.64.1 (all installed). iOS Simulator runtime present: iOS 26.3.
- **Swift 6 package blocker is exactly one site:** `AuraCore/Sources/AuraCore/Playback/GPXParser.swift:22`, a `private static let iso = ISO8601DateFormatter()`. Nothing else in AuraCore or AuraKit fails under Swift 6 (library targets were probed with `-swift-version 6`). The test targets were not probed, so Task 3 must fix anything that surfaces there.
- **SwiftLint default-rule landscape: 187 violations.** 137 are `identifier_name`, all idiomatic short names (`s`, `t`, `i`, `p`, `vm`, `dx`, `px`, `dt`, `el`, …) — tune `min_length`, do not rename. ~31 are autocorrectable (`trailing_comma` 19, `redundant_optional_initialization` 3, `comma_spacing` 3, `colon` 3, `trailing_newline` 2, `statement_position` 1). The remaining manual set is small and enumerated in Task 1.
- **Local build prerequisites are in place:** `Aura/Resources/MapboxAccessToken` exists in this worktree, and `~/.netrc` has the `api.mapbox.com` machine, so `xcodebuild` resolves Mapbox locally without extra setup.

## Cross-cutting rules for every task

- **Stage only the files each task names.** In particular, NEVER `git add AuraCore/Package.resolved`. App builds (xcodebuild) write Mapbox pins into the pure package's lockfile; if it shows up dirty, revert it with `git checkout -- AuraCore/Package.resolved` before committing.
- **Keep the gate green as you go.** After Task 1 lands, every later task ends with `./scripts/lint.sh` clean before committing. After Task 3, every later task keeps `swift test` green.
- **Commit messages** end with the trailer:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- **Run SwiftLint without `--config`** (from the repo root) so the root `.swiftlint.yml` is auto-discovered and the nested `AuraCore/Tests/.swiftlint.yml` is merged per file. Passing `--config` disables nested-config lookup.

---

## Task 1: SwiftLint config + cleanup to green under `--strict`

Add the configuration, autocorrect the mechanical violations, hand-fix the small remainder, and land the repo clean under `swiftlint --strict`. Consult @all-ios-skills:swiftlint.

**Files:**
- Create: `.swiftlint.yml`
- Create: `AuraCore/Tests/.swiftlint.yml`
- Create: `scripts/lint.sh`
- Modify: assorted source files flagged by SwiftLint (see steps)

- [ ] **Step 1: Write the root config**

Create `.swiftlint.yml`:

```yaml
# SwiftLint configuration for Aura. CI runs `swiftlint --strict`; any violation,
# warning or error, fails the build. The team decision is to keep SwiftLint's
# default rule set and tune only the rules that clash with established
# conventions in this codebase. Each tuning is documented inline.

included:
  - AuraCore/Sources
  - AuraCore/Tests
  - Aura/Sources
  - Aura/Widgets

excluded:
  - .build
  - DerivedData
  - docs

disabled_rules:
  # The codebase uses `TODO(Wave N)` markers intentionally to track deferred
  # roadmap work. Flagging them would fight that convention.
  - todo

identifier_name:
  # The geo/stats/SwiftUI code uses idiomatic single- and two-letter names for
  # loop indices, math and vector variables (dx, dt, px), and closure
  # parameters (s, p, f). They read clearly in context; renaming them would
  # reduce clarity. The rest of identifier_name (casing, max length) stays on.
  min_length:
    warning: 1
    error: 0

line_length:
  # 120 is tight for SwiftUI modifier chains and Mapbox option builders. 140 is
  # common practice; anything past 140 is still wrapped by hand.
  warning: 140
  error: 200

file_length:
  # A couple of view files run ~400-450 lines today. 500 is a reasonable
  # ceiling; splitting large views is deferred to the design-system sub-project.
  warning: 500
  error: 1200
```

- [ ] **Step 2: Write the test child config**

Create `AuraCore/Tests/.swiftlint.yml` (merged on top of the root config for files under `AuraCore/Tests`):

```yaml
# Test-code tolerances. Inherits the root config; relaxes rules that are
# acceptable in tests, where force-unwrapping a known-good fixture is clearer
# than defensive optionality.
disabled_rules:
  - force_try
  - force_cast
```

- [ ] **Step 3: Write the local lint script**

Create `scripts/lint.sh`:

```bash
#!/usr/bin/env bash
# Local convenience: lint the repo exactly as CI does. Run from anywhere.
set -euo pipefail
cd "$(dirname "$0")/.."
exec swiftlint lint --strict
```

Then `chmod +x scripts/lint.sh`.

- [ ] **Step 4: Autocorrect the mechanical violations**

```bash
swiftlint --fix
```

Expected: roughly 31 violations corrected (`trailing_comma`, `redundant_optional_initialization`, `comma_spacing`, `colon`, `trailing_newline`, `statement_position`). Review the diff — every change should be pure formatting, no semantic change.

- [ ] **Step 5: Commit config + autocorrect**

```bash
git add .swiftlint.yml AuraCore/Tests/.swiftlint.yml scripts/lint.sh
git add -A AuraCore/Sources Aura/Sources Aura/Widgets AuraCore/Tests
git status   # confirm AuraCore/Package.resolved is NOT staged
git commit -m "chore(lint): add SwiftLint config and autocorrect mechanical violations

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 6: See what remains**

```bash
swiftlint lint --strict
```

Expected residual violations (from recon, after the config tunings and autocorrect remove the rest):
- `line_length` (a few lines over 140): wrap them. Candidate sites: `Aura/Sources/Routing/MapboxRoutingProvider.swift:123,131`, `Aura/Sources/Plan/RoutePreviewView.swift:310`, `Aura/Sources/Routing/MapboxTerrainRGBElevationProvider.swift:108`, `AuraCore/Tests/AuraKitTests/TurnCardPresenterTests.swift:13,14,18` (only those that still exceed 140 after the threshold bump).
- `multiple_closures_with_trailing_closure` (2): `Aura/Sources/Ride/RideHUDView.swift:48`, `Aura/Sources/Ride/NavigateHUDView.swift:119`. Rewrite so no closure uses trailing-closure syntax when more than one closure is passed (give the final closure an explicit argument label).
- `vertical_parameter_alignment` (1): `Aura/Widgets/RideLiveActivity.swift:109`. Align the wrapped parameters.
- `function_body_length` (2): `Aura/Sources/Routing/MapboxRoutingProvider.swift:34`, `Aura/Sources/Routing/MapboxGuidanceSession.swift:29`. These are linear Mapbox-v3 setup blocks where splitting would obscure the configuration sequence. Add a targeted suppression with a reason on each, e.g. `// swiftlint:disable:next function_body_length // Mapbox v3 setup is one linear configuration block; splitting hides the sequence`.

`file_length` for `Aura/Sources/Plan/RoutePreviewView.swift` (402 lines) is cleared by the 500 threshold; do not split it here.

Fix each residual. For any `line_length` site, prefer wrapping over a suppression.

- [ ] **Step 7: Verify clean**

```bash
./scripts/lint.sh
echo "exit: $?"
```

Expected: no output, exit 0.

- [ ] **Step 8: Confirm the package still tests green (no semantic drift from autocorrect)**

```bash
cd AuraCore && swift test
```

Expected: all tests pass (115 today). Return to repo root.

- [ ] **Step 9: Commit the manual fixes**

```bash
git add -A AuraCore/Sources Aura/Sources Aura/Widgets AuraCore/Tests
git status   # confirm AuraCore/Package.resolved is NOT staged
git commit -m "chore(lint): hand-fix remaining violations, repo green under --strict

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Fix the one Swift 6 package blocker (behavior-preserving, still Swift 5)

Make `GPXParser`'s date formatter an instance property instead of a shared static. The `Delegate` is created fresh per `parse()` call, so an instance `let` is functionally identical and removes the non-Sendable global without any unsafe annotation. Consult @all-ios-skills:swift-concurrency.

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Playback/GPXParser.swift` (lines 22–24 and 41)
- Test: existing `AuraCore/Tests/AuraCoreTests/GPXParserTests.swift`, `GPXParserEdgeTests.swift` (no new test needed; these already cover timestamp parsing)

- [ ] **Step 1: Confirm the tests that protect this exist and pass**

```bash
cd AuraCore && swift test --filter GPXParser
```
Expected: PASS (these tests parse GPX timestamps, so they will catch any regression in the formatter change). Return to repo root.

- [ ] **Step 2: Make the formatter an instance property**

In `AuraCore/Sources/AuraCore/Playback/GPXParser.swift`, change the declaration (currently lines 22–24):

```swift
        private static let iso: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
        }()
```

to a non-static instance property:

```swift
        // Instance-level (one per parse) rather than a shared static: a shared
        // static ISO8601DateFormatter is a non-Sendable global that Swift 6
        // strict concurrency rejects. The Delegate is created fresh per parse,
        // so this is functionally identical.
        private let iso: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
        }()
```

And change the use site (currently line 41) from `Self.iso.date(...)` to `iso.date(...)`:

```swift
            case "time": time = iso.date(from: buffer.trimmingCharacters(in: .whitespacesAndNewlines))
```

- [ ] **Step 3: Verify tests still pass (behavior preserved on Swift 5)**

```bash
cd AuraCore && swift test --filter GPXParser
```
Expected: PASS. Return to repo root.

- [ ] **Step 4: Verify the site now compiles under Swift 6 (probe, no manifest change)**

```bash
cd AuraCore && swift build --target AuraCore -Xswiftc -swift-version -Xswiftc 6 2>&1 | grep -iE "error:" || echo "no errors under Swift 6"
```
Expected: `no errors under Swift 6` (the GPXParser error is gone; nothing else breaks). Return to repo root.

- [ ] **Step 5: Run the full package suite and lint**

```bash
cd AuraCore && swift test && cd .. && ./scripts/lint.sh
```
Expected: all tests pass; lint clean.

- [ ] **Step 6: Commit**

```bash
git add AuraCore/Sources/AuraCore/Playback/GPXParser.swift
git commit -m "fix(core): make GPXParser date formatter instance-scoped for Swift 6

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Flip the package to Swift 6 language mode

Bump the manifest to tools-version 6.0 and declare Swift 6 language mode. With tools-version 6.0 every target (AuraCore, AuraKit, both test targets) defaults to Swift 6; the explicit `swiftLanguageModes: [.v6]` documents that. Fix any Swift 6 errors that surface in the test targets (the library targets are already clean after Task 2). Consult @all-ios-skills:swift-concurrency.

**Files:**
- Modify: `AuraCore/Package.swift` (the `// swift-tools-version` line and the `Package(...)` initializer)

- [ ] **Step 1: Bump tools-version and declare Swift 6 mode**

In `AuraCore/Package.swift`, change the first line from:

```swift
// swift-tools-version: 5.10
```
to:
```swift
// swift-tools-version: 6.0
```

Then add `swiftLanguageModes: [.v6]` to the `Package(...)` initializer (as the last argument after `targets:`):

```swift
let package = Package(
    name: "AuraCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AuraCore", targets: ["AuraCore"]),
        .library(name: "AuraKit", targets: ["AuraKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
    ],
    targets: [
        .target(name: "AuraCore"),
        .testTarget(
            name: "AuraCoreTests",
            dependencies: [
                "AuraCore",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ]
        ),
        .target(name: "AuraKit", dependencies: ["AuraCore"]),
        .testTarget(name: "AuraKitTests", dependencies: ["AuraKit"]),
    ],
    swiftLanguageModes: [.v6]
)
```

Do not add default MainActor isolation — these are libraries and must stay actor-agnostic.

- [ ] **Step 2: Build the library targets under Swift 6**

```bash
cd AuraCore && swift build 2>&1 | grep -iE "error:" || echo "library build clean"
```
Expected: `library build clean`.

- [ ] **Step 3: Run the full suite (compiles the test targets under Swift 6)**

```bash
cd AuraCore && swift test
```
Expected: all tests pass. If a test target fails to compile under Swift 6, fix it with the smallest safe change per @all-ios-skills:swift-concurrency (annotate isolation, snapshot an immutable value; never `nonisolated(unsafe)` or `@unchecked Sendable` to silence it). Re-run until green. Return to repo root.

- [ ] **Step 4: Lint**

```bash
./scripts/lint.sh
```
Expected: clean (if you touched any test files, they stay lint-clean).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Package.swift   # plus any test files you had to fix
git status   # confirm AuraCore/Package.resolved is NOT staged
git commit -m "build(core): adopt Swift 6 language mode for AuraCore and AuraKit

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Swift 6 + approachable concurrency on the app and widget

Set Swift 6 language mode plus the executable concurrency posture (Approachable Concurrency, Default Actor Isolation = MainActor) on both the `Aura` app target and the `AuraWidgets` extension in `Aura/project.yml`, then build with `xcodebuild` and fix whatever Swift 6 surfaces. This is the one task with real unknowns; budget for iteration. Consult @all-ios-skills:swift-concurrency. Delegate the actual builds to @apple-platform-build-tools:builder so the verbose logs stay out of your context, or run `xcodebuild` directly if you prefer.

**Files:**
- Modify: `Aura/project.yml` (the `settings: base:` block of the `Aura` target and of the `AuraWidgets` target)
- Modify: app/widget Swift sources as needed for Swift 6 (expected: a few `@preconcurrency import` additions, possibly a small number of isolation annotations)

- [ ] **Step 1: Add the language-mode + isolation settings to both targets**

In `Aura/project.yml`, add these three keys to the `settings: base:` block of BOTH the `Aura` target and the `AuraWidgets` target (keep the existing keys in each block):

```yaml
        SWIFT_VERSION: "6.0"
        SWIFT_APPROACHABLE_CONCURRENCY: YES
        SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor
```

Note on setting names: `SWIFT_VERSION` is certain. The other two are the Xcode 26 build settings for the Swift 6.2 "approachable concurrency" posture. After generating in Step 2, verify they were understood (Step 3); if a key is not recognized by this toolchain, fall back to `OTHER_SWIFT_FLAGS: "$(inherited) -default-isolation MainActor"` for the isolation piece and rely on `SWIFT_VERSION: "6.0"` for the language mode, and note the substitution in the commit.

- [ ] **Step 2: Regenerate the project**

```bash
cd Aura && xcodegen generate && cd ..
```
Expected: `Created project at Aura/Aura.xcodeproj`.

- [ ] **Step 3: Confirm the settings landed**

```bash
cd Aura && xcodebuild -showBuildSettings -scheme Aura 2>/dev/null | grep -iE "SWIFT_VERSION|ACTOR_ISOLATION|APPROACHABLE" | sort -u; cd ..
```
Expected: `SWIFT_VERSION = 6.0` and the isolation/approachable settings present. If the isolation keys are absent, apply the `OTHER_SWIFT_FLAGS` fallback from Step 1 and regenerate.

- [ ] **Step 4: Build the app (this also builds the embedded AuraWidgets extension)**

```bash
cd Aura && xcodebuild build -project Aura.xcodeproj -scheme Aura -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -40; cd ..
```
Expected eventually: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Fix Swift 6 diagnostics, smallest safe fix first**

For each error, apply the @all-ios-skills:swift-concurrency triage:
- Mapbox SDK types failing `Sendable` across an isolation boundary → `@preconcurrency import MapboxMaps` (and `MapboxNavigationCore` / `MapboxSearch` etc. as needed), with a short comment that it is removable when the SDK adds `Sendable`.
- App/widget types that should be main-actor → rely on the inferred default isolation; add an explicit `@MainActor` only where inference does not reach.
- Never silence a Mapbox diagnostic with `nonisolated(unsafe)` or `@unchecked Sendable`.

Re-run Step 4 until `** BUILD SUCCEEDED **`. Revert any `AuraCore/Package.resolved` churn: `git checkout -- AuraCore/Package.resolved`.

- [ ] **Step 6: Keep the package and lint green**

```bash
cd AuraCore && swift test && cd .. && ./scripts/lint.sh
```
Expected: tests pass; lint clean (any `@preconcurrency import` lines lint fine; if you added a long line, wrap it).

- [ ] **Step 7: Commit**

```bash
git add Aura/project.yml Aura/Sources Aura/Widgets
git status   # confirm AuraCore/Package.resolved is NOT staged (revert if it is)
git commit -m "build(app): adopt Swift 6 mode + approachable concurrency for app and widget

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: CI workflow — app-build + lint jobs, plus secrets and roadmap

Extend the workflow into three parallel jobs and document the two secrets the app build needs. The app build and lint commands were already proven locally in Tasks 1 and 4, so verification here is YAML validity plus confirming the local equivalents pass.

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `docs/ROADMAP.md`

- [ ] **Step 1: Rewrite the workflow with three jobs**

Replace `.github/workflows/ci.yml` with:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  package-tests:
    name: AuraCore tests (swift test)
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - uses: maxim-lobanov/setup-xcode@v1
        with:
          xcode-version: latest-stable
      - name: Show Swift version
        run: swift --version
      # Pure-logic package, now under Swift 6 language mode. No simulator, no Mapbox token.
      - name: Run AuraCore + AuraKit tests
        working-directory: AuraCore
        run: swift test

  app-build:
    name: App build (xcodebuild)
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - uses: maxim-lobanov/setup-xcode@v1
        with:
          xcode-version: latest-stable
      - name: Install XcodeGen
        run: brew install xcodegen
      - name: Write Mapbox credentials
        env:
          MAPBOX_DOWNLOADS_TOKEN: ${{ secrets.MAPBOX_DOWNLOADS_TOKEN }}
          MAPBOX_PUBLIC_TOKEN: ${{ secrets.MAPBOX_PUBLIC_TOKEN }}
        run: |
          umask 077
          printf 'machine api.mapbox.com\n  login mapbox\n  password %s\n' "$MAPBOX_DOWNLOADS_TOKEN" > "$HOME/.netrc"
          printf '%s' "$MAPBOX_PUBLIC_TOKEN" > Aura/Resources/MapboxAccessToken
      - name: Generate project
        working-directory: Aura
        run: xcodegen generate
      - name: Build app (also builds the embedded AuraWidgets extension)
        working-directory: Aura
        run: |
          xcodebuild build \
            -project Aura.xcodeproj \
            -scheme Aura \
            -destination 'generic/platform=iOS Simulator' \
            CODE_SIGNING_ALLOWED=NO

  lint:
    name: SwiftLint (--strict)
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Install pinned SwiftLint
        run: |
          curl -fsSL -o /tmp/swiftlint.zip \
            https://github.com/realm/SwiftLint/releases/download/0.64.1/portable_swiftlint.zip
          mkdir -p /tmp/swiftlint && unzip -o /tmp/swiftlint.zip -d /tmp/swiftlint
          echo "/tmp/swiftlint" >> "$GITHUB_PATH"
      - name: Lint
        run: swiftlint lint --strict
```

- [ ] **Step 2: Validate the YAML parses**

```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml')); print('YAML OK')"
```
Expected: `YAML OK`.

- [ ] **Step 3: Re-confirm the local equivalents of each job pass**

```bash
cd AuraCore && swift test && cd ..        # package-tests job
./scripts/lint.sh                          # lint job (pinned version matches local 0.64.1)
```
Expected: tests pass; lint clean. (The app-build job equivalent — `xcodegen generate` + `xcodebuild build -scheme Aura` — was proven in Task 4 Step 4; no need to rebuild here.)

- [ ] **Step 4: Update the roadmap**

In `docs/ROADMAP.md`:
- Under "Wave 1 — Structural foundations", mark the **Quality gates** bullet as shipped (date 2026-06-24), noting: app target plus AuraWidgets extension now compiled by `xcodebuild` in CI, Swift 6 language mode across all four compiled targets, SwiftLint `--strict` with a tuned default rule set.
- In the audit "app target is untested and unbuilt in CI" finding, add a resolved note: the app is now built and linted in CI; it remains untested (app-target tests are still later work).
- In "Testing", update the CI description: CI now runs three jobs (package tests under Swift 6, app build, SwiftLint `--strict`); the package test count is unchanged (115; this sub-project added no tests).
- Keep edits factual and concise; run the prose through the @humanizer lens (no em dashes, no inflated language).

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci.yml docs/ROADMAP.md
git commit -m "ci: build the app and lint under --strict; mark Wave 1 quality gates shipped

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 6: Hand the secrets to the user (do not attempt to set them yourself)**

The `app-build` job stays red until the two repository secrets exist. Tell the user to run, from the repo, and paste each token when prompted:

```bash
gh secret set MAPBOX_DOWNLOADS_TOKEN   # paste the sk.… Downloads:Read token (same value as ~/.netrc password)
gh secret set MAPBOX_PUBLIC_TOKEN      # paste the pk.… runtime token (contents of Aura/Resources/MapboxAccessToken)
```

---

## Done criteria

- `swiftlint --strict` is clean across AuraCore/Sources, AuraCore/Tests, Aura/Sources, Aura/Widgets, with all tunings documented in `.swiftlint.yml`.
- `AuraCore/Package.swift` is tools-version 6.0 with `swiftLanguageModes: [.v6]`; `swift test` is green (115 tests).
- `xcodegen generate` + `xcodebuild build -scheme Aura` succeeds with Swift 6 mode on the app and the `AuraWidgets` extension.
- `.github/workflows/ci.yml` has `package-tests`, `app-build`, and `lint` jobs; the YAML parses; the local equivalents pass.
- `docs/ROADMAP.md` reflects the shipped quality gates.
- No runtime behavior changed; `AuraCore/Package.resolved` is unmodified.
