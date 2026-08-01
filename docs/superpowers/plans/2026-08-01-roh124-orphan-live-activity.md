# Orphaned Live Activity sweep (ROH-124) implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** End the Live Activity a killed process left on the Lock Screen, at the next launch, at
the next foreground, and before the next ride requests its own.

**Architecture:** One synchronous method on `RideLiveActivityController` snapshots
`Activity<RideActivityAttributes>.activities`, excludes what this process owns or is already
ending, claims the rest, and ends them sequentially on the main actor. Three call sites in the app
target use it. Nothing joins the AuraKit seam.

**Tech Stack:** Swift 6, SwiftUI, ActivityKit, XcodeGen (`Aura/project.yml`), swift-testing.

**Spec:** `docs/superpowers/specs/2026-08-01-roh124-orphan-live-activity-design.md` (revision 3).
Read D1, D2, D3 and D5 before starting. The spec records several reversals; the *current* text is
what to build, and the italic paragraphs explain why obvious-looking alternatives were rejected.

## Global constraints

- **Never introduce a suspension point between the `Activity.activities` snapshot and the owned-id
  read.** That gap is the one defect that ends a live ride's Live Activity for the rest of the
  ride, silently, with nothing able to detect it.
- **The owned id comes from `activity?.id` and nowhere else.** Not `ride.id.uuidString`, not
  `router.activeRideID`.
- **One commit, both halves.** `endOrphans()` and its call sites land together. SwiftLint runs
  `lint`, not `analyze`, so a method with no callers passes every gate this repo has; splitting
  the primitive from the wiring would produce a green commit that does nothing.
- **Sequential ends. No `TaskGroup`, no per-activity detached Task.** This compiles either way on
  the pinned toolchain, so the constraint is a judgment call, not the compiler's: there is nothing
  to gain from ending two dying activities at once, and the parallel form multiplies the
  `sending Activity` pattern ROH-116 was filed about.
- Delegate the app build to the `apple-platform-build-tools:builder` subagent. Do not run
  `xcodebuild` in the main session.

## File structure

| File | Responsibility |
|---|---|
| `AuraCore/Sources/AuraKit/Testing/SimulatedRideConfig.swift` | The `-skipOrphanSweep` launch-flag predicate, beside the existing flags |
| `AuraCore/Tests/AuraKitTests/SimulatedRideConfigTests.swift` | Its test |
| `Aura/Sources/LiveActivity/RideLiveActivityController.swift` | `endingIDs`, `endOrphans()`, the `end()` bookkeeping, the `start()` call site |
| `Aura/Sources/LiveActivity/RideActivityAttributes.swift` | Comment only: the decode rule now also decides whether a ghost is reachable |
| `Aura/Sources/AuraApp.swift` | The launch and foreground call sites |

---

### Task 1: The sweep, its call sites, and the suppression flag

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Testing/SimulatedRideConfig.swift`
- Modify: `AuraCore/Tests/AuraKitTests/SimulatedRideConfigTests.swift`
- Modify: `Aura/Sources/LiveActivity/RideLiveActivityController.swift`
- Modify: `Aura/Sources/LiveActivity/RideActivityAttributes.swift`
- Modify: `Aura/Sources/AuraApp.swift`

**Interfaces:**
- Produces: `@MainActor func endOrphans()` on `RideLiveActivityController`, synchronous, no return
  value, safe to call at any time including mid-ride;
  `SimulatedRideConfig.suppressesOrphanSweep(arguments:) -> Bool` and the
  `@MainActor static let currentSuppressesOrphanSweep`.

**Anchors, not line numbers.** Every edit below names the code it sits next to. Do not navigate by
the line numbers in the spec: earlier steps in this task shift them.

- [ ] **Step 1: Write the failing test for the launch flag**

In `AuraCore/Tests/AuraKitTests/SimulatedRideConfigTests.swift`, directly after the existing
`inMemoryStoreFlag` test:

```swift
    @Test func skipOrphanSweepFlag() {
        #expect(SimulatedRideConfig.suppressesOrphanSweep(arguments: ["App", "-skipOrphanSweep"]))
        #expect(!SimulatedRideConfig.suppressesOrphanSweep(arguments: ["App"]))
        #expect(!SimulatedRideConfig.suppressesOrphanSweep(arguments: ["App", "-skipOrphanSweepX"]))
    }
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd AuraCore && swift test --no-parallel --filter SimulatedRideConfigTests
```

Expected: compile failure, no member `suppressesOrphanSweep`.

- [ ] **Step 3: Add the predicate**

In `SimulatedRideConfig`, directly after `forcesInMemoryStore(arguments:)`:

```swift
    /// "-skipOrphanSweep" → suppress the launch and foreground orphan-Live-Activity sweeps
    /// (ROH-124), so a device pass can exercise the `start()` sweep on its own. Deliberately does
    /// not reach that third call site.
    public static func suppressesOrphanSweep(arguments: [String]) -> Bool {
        arguments.contains("-skipOrphanSweep")
    }
```

And beside the other process-wide statics at the bottom of the type:

```swift
    @MainActor public static let currentSuppressesOrphanSweep =
        suppressesOrphanSweep(arguments: ProcessInfo.processInfo.arguments)
```

- [ ] **Step 4: Run the test and watch it pass**

```bash
cd AuraCore && swift test --no-parallel --filter SimulatedRideConfigTests
```

Expected: PASS.

- [ ] **Step 5: Add `endingIDs` to the controller**

In `RideLiveActivityController`, in the stored-property block, directly below the `pushChain`
declaration and its comment:

```swift
    /// Ids some path in this process is already ending, so a sweep does not end them a second
    /// time. Both writers matter (spec D2): `end()` nils `activity` synchronously but performs the
    /// ActivityKit end later, after draining `pushChain`, and `endOrphans()` claims its snapshot
    /// before spawning because a cold launch fires two sweeps within milliseconds and ActivityKit
    /// removes an ended activity from `activities` asynchronously.
    private var endingIDs: Set<String> = []
```

- [ ] **Step 6: Claim and release the id in `end()`**

`end()` currently nils `activity`, snapshots `pushChain`, and spawns a `Task { @MainActor in … }`.
Rewrite the tail of it so the whole method reads:

```swift
    func end() {
        guard let activity else { return }
        self.activity = nil
        let final = lastPayload ?? RideActivityPayload(clock: .running(anchor: Date()))
        lastPayload = nil
        lastPushedAt = nil

        let id = activity.id
        endingIDs.insert(id)
        let previous = pushChain
        pushChain = nil
        Task { @MainActor [self] in
            // `defer` rather than a trailing statement: an id stranded in `endingIDs` is excluded
            // from every later sweep for the life of the process, which would blind the one
            // mechanism that clears ghosts. Capturing `self` strongly is fine and deliberate —
            // this is a `static let` singleton that is never deallocated.
            defer { endingIDs.remove(id) }
            // Drain what is already queued, so the end is the last thing the activity sees.
            await previous?.value
            await activity.end(
                ActivityContent(state: RideActivityAttributes.ContentState(payload: final),
                                staleDate: nil),
                dismissalPolicy: .immediate)
        }
    }
```

- [ ] **Step 7: Add `endOrphans()` directly below `end()`**

```swift
    /// Ends every Live Activity this process does not own: what a previous process left behind
    /// when it was killed mid-ride. Nothing else can reach one. `end()` and `update()` are both
    /// gated on the in-memory `activity`, which a fresh singleton has lost, so after a jetsam kill
    /// the ghost outlives every path that could clear it (spec D1).
    ///
    /// **Synchronous up to the point the orphan set is fixed, and that is the entire safety
    /// argument.** The snapshot and the owned-id read happen in one main-actor turn with no
    /// suspension between them, so no ride can start in the gap and the set captured below can
    /// never contain an activity this process owns. Do not add an `await` above `orphans`, and do
    /// not source the owned id from anywhere but `activity?.id`: a ride's `id.uuidString` is a
    /// different value that matches nothing, which would make *every* activity an orphan,
    /// including the one the current ride is using.
    ///
    /// Sequential on purpose, and not because the parallel form fails to compile — it does
    /// compile. There is nothing to gain from ending two dying activities at once, and a
    /// `TaskGroup` would multiply the `sending Activity` pattern ROH-116 was about.
    func endOrphans() {
        let owned = activity?.id
        let orphans = Activity<RideActivityAttributes>.activities.filter {
            // `.ended`/`.dismissed` are already on their way out, and `endingIDs.remove` fires
            // when ActivityKit accepts an end rather than when the entry leaves this list.
            $0.activityState != .ended && $0.activityState != .dismissed
                && $0.id != owned && !endingIDs.contains($0.id)
        }
        guard !orphans.isEmpty else { return }
        for orphan in orphans { endingIDs.insert(orphan.id) }

        Task { @MainActor [self] in
            for orphan in orphans {
                defer { endingIDs.remove(orphan.id) }
                // The recovered activity still carries the dead process's last state, and Apple's
                // guidance for `end` is to pass a final content update rather than nil.
                await orphan.end(
                    ActivityContent(state: orphan.content.state, staleDate: nil),
                    dismissalPolicy: .immediate)
            }
        }
    }
```

- [ ] **Step 8: Call it at the top of `start()`**

`start()` opens with the comment "Defensive: clear any activity a previous ride somehow left
running." and the `end()` call. Insert above that comment:

```swift
        // First, so it runs unconditionally (spec D3). Placed after the request instead, it is
        // skipped when the rider has Live Activities turned off and skipped again when the
        // request throws, which leaves the ghost to outlive the whole session in both cases.
        // It does *not* free a slot for the request below: the ends happen in a Task, and this
        // function never suspends.
        endOrphans()
```

- [ ] **Step 9: Extend the decode rule's comment**

In `RideActivityAttributes.swift`, the doc comment on `ContentState` ends with "…so this rule is
the whole guarantee (ROH-102 spec D2, invariant 6)." Replace that closing sentence with:

```swift
    /// rule is the whole guarantee (ROH-102 spec D2, invariant 6).
    ///
    /// It binds the outer `RideActivityAttributes` stored properties below just as tightly, and
    /// since ROH-124 it also decides whether a ghost can be cleared at all: an activity written by
    /// a previous binary that this one cannot decode never appears in
    /// `Activity<RideActivityAttributes>.activities`, so the orphan sweep cannot see it and
    /// nothing will ever end it.
```

- [ ] **Step 10: Add the launch sweep to RootView**

In `AuraApp.swift`, find the 18-line comment block that begins "Schema V6's segment backfill
(ROH-100). Deliberately not in the V5→V6 migration stage" and documents the `.task` below it.
Insert the new modifier **above that entire comment block**, so the comment stays attached to the
backfill `.task` it describes:

```swift
        // Ghost Live Activities a killed process left behind (ROH-124).
        //
        // Its own `.task`, not the backfill one below. That closure is synchronous end to end, and
        // its `guard backfill == nil` check-then-set is idempotent on a scene reconnect only
        // because nothing between the read and the write can yield. An `await` added there would
        // let two invocations both observe nil and spawn two concurrent 50-row backfill sweeps on
        // one ModelContainer.
        //
        // Unguarded by ride state on purpose: `endOrphans()` excludes the activity it owns, and
        // `router.activeRideID` lags `coordinator.isRecording` by an update cycle, so it is nil
        // during a window in which a ride is already recording and owns an activity.
        .task {
            guard !SimulatedRideConfig.currentSuppressesOrphanSweep else { return }
            RideLiveActivityController.shared.endOrphans()
        }
```

- [ ] **Step 11: Add the foreground sweep**

In the existing `.onChange(of: scenePhase)`, inside the `if phase == .active` branch, directly
after the `WidgetRefresh.reload(...)` call:

```swift
                // A session that launched before ActivityKit had restored its activity list, or
                // whose first request threw, would otherwise carry the ghost for the life of the
                // process (ROH-124). A no-op mid-ride: the running activity is the owned one.
                if !SimulatedRideConfig.currentSuppressesOrphanSweep {
                    RideLiveActivityController.shared.endOrphans()
                }
```

- [ ] **Step 12: Build the app**

Dispatch the `apple-platform-build-tools:builder` subagent: "Build the Aura scheme for an iOS
Simulator destination in
`/Users/rohunjoseph/projects/biking-app/.claude/worktrees/session-103-work-availability-b0ce14`.
Report only success or the first error."

Expected: build succeeds. If `activityState` does not resolve, check the SDK: it is
`Activity.activityState` returning `ActivityState`, with cases `.active`, `.dismissed`, `.ended`,
`.pending`, `.stale`.

- [ ] **Step 13: Run the full local gate**

```bash
scripts/lint.sh && scripts/check-explore-rename.sh && scripts/check-terrain-style.sh && (cd AuraCore && swift test --no-parallel)
```

Expected: all green. This is the same set `.claude/agent-gate.sh` runs, which is wider than lint
plus tests.

**Know what this gate proves: almost nothing about this change.** It proves the launch flag parses
and that nothing else regressed. No automated check in this repo can observe an activity being
ended. The spec's device pass is the real gate and is owed before ROH-124 moves to Done.

- [ ] **Step 14: Commit**

```bash
git add AuraCore/Sources/AuraKit/Testing/SimulatedRideConfig.swift AuraCore/Tests/AuraKitTests/SimulatedRideConfigTests.swift Aura/Sources/LiveActivity/RideLiveActivityController.swift Aura/Sources/LiveActivity/RideActivityAttributes.swift Aura/Sources/AuraApp.swift
git commit -m "feat(roh-124): end Live Activities orphaned by a killed process"
```

---

## What this plan does not do

The device pass in the spec's Verification section needs a physical phone, a Lock Screen, and a
deliberate process kill, so it is not a task here. It is owed before ROH-124 moves to Done, and
steps 3, 4, 5 and 7 of that list are the ones that can still fail after everything above is green.
Note that this repo has previously had a PR merge silently mark a verification issue Done; check
ROH-124's state after the merge rather than trusting it.
