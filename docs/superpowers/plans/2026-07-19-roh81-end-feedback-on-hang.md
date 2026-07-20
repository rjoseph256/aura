# ROH-81 End/Leave Feedback On Hang — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give a group-ride host/member immediate "Ending…" feedback plus a 4s timeout that surfaces the existing "Couldn't end — Retry" chip when the end/leave network call hangs, without misfiring on the keep-riding leave path.

**Architecture:** All timing lives in AuraKit's `GroupRideSession` behind two injected, defaulted seams (`endTimeout`, `sleep`) so it is deterministically unit-testable. A new `FinishIntent` distinguishes host-end / member-end (waited-on, show feedback) from member-leave-keep-riding (fire-and-forget, no feedback). A small structured `withTimeout` helper races the backend call against `sleep`. The app renders an on-theme "Ending…" pill, disables the End control while pending, and adds a failure haptic + VoiceOver announcements.

**Tech Stack:** Swift 6, Swift Concurrency (`withThrowingTaskGroup`, `Duration`, `Task.sleep(for:)`), SwiftUI, Swift Testing, SwiftLint (strict).

## Global Constraints

- Swift 6 strict concurrency; all targets must build clean. `GroupRideSession` is `@MainActor @Observable`.
- Timeout value: **4 seconds** (`.seconds(4)`), injected via a defaulted `init` param so no production call site changes.
- New `init` params MUST be defaulted (`endTimeout: Duration = .seconds(4)`, `sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }`) so the app's construction site is untouched.
- Pending/timeout/chip/disable feedback applies to **`.hostEnd` and `.memberEnd` only**. `.memberLeave` (keep riding) stays fire-and-forget: no `isEnding`, no `endFailed`, no chip, no disabled stop button.
- Copy: pill text "Ending…"; a11y label "Ending the group ride"; failure announcement "Couldn't end the group ride. Retry available." (No "Leaving…" variant — `.memberLeave` never shows a pill.)
- Idempotency: `end_ride`/`leave_ride` are idempotent; a late success + a retry both converge (retry hits `notHost`/`notMember` → success).
- `swiftlint --strict` must be clean before any merge (local merges skip CI lint).
- Follow existing patterns: status pills mirror `reconnectingPill`/`endFailedPill`; test spies mirror `InMemoryGroupRideBackend`'s `forceEndError`/`leaveCalled` style; delegate all builds to the `apple-platform-build-tools:builder` agent.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `AuraCore/Sources/AuraKit/GroupRide/Timeout.swift` | **new** — generic `withTimeout` + `TimeoutError` |
| `AuraCore/Sources/AuraKit/GroupRide/GroupRideSession.swift` | intent, seams, `isEnding`, `finishRide` rewrite, `teardownLive` latch-clear |
| `AuraCore/Sources/AuraKit/GroupRide/InMemoryGroupRideBackend.swift` | add hang/entry/call-count test hooks (spy pattern) |
| `Aura/Sources/Ride/ControlCluster.swift` | defaulted `isEndDisabled` param on the End button |
| `Aura/Sources/Ride/NavigateHUDView+GroupCrew.swift` | `endingPill`; `endRideAsMember` → `endAsMember()` |
| `Aura/Sources/Ride/NavigateHUDView.swift` | render `endingPill`; pass `isEndDisabled`; failure haptic + VoiceOver |
| `AuraCore/Tests/AuraKitTests/GroupRide/GroupRideEndTimeoutTests.swift` | **new** — all new AuraKit tests + `AsyncGate` helper |

---

## Task 1: `withTimeout` timeout helper

**Files:**
- Create: `AuraCore/Sources/AuraKit/GroupRide/Timeout.swift`
- Test: `AuraCore/Tests/AuraKitTests/GroupRide/GroupRideEndTimeoutTests.swift` (new; also hosts later tasks' tests)

**Interfaces:**
- Produces:
  - `struct TimeoutError: Error, Equatable {}`
  - `func withTimeout<T: Sendable>(_ duration: Duration, sleep: @Sendable @escaping (Duration) async throws -> Void, operation: @Sendable @escaping () async throws -> T) async throws -> T` (internal to AuraKit)

- [ ] **Step 1: Write the failing tests**

Create `AuraCore/Tests/AuraKitTests/GroupRide/GroupRideEndTimeoutTests.swift`:

```swift
import Testing
import Foundation
@testable import AuraKit

@MainActor
struct WithTimeoutTests {
    @Test func operationWinsReturnsValue() async throws {
        // Instant operation, never-firing sleep → operation value returned.
        let value = try await withTimeout(.seconds(1), sleep: { _ in
            try await Task.sleep(for: .seconds(1000))
        }, operation: { 42 })
        #expect(value == 42)
    }

    @Test func timeoutWinsThrowsTimeoutError() async {
        // Instant sleep, parked operation → TimeoutError.
        await #expect(throws: TimeoutError.self) {
            try await withTimeout(.seconds(1), sleep: { _ in }, operation: {
                try await Task.sleep(for: .seconds(1000))
            })
        }
    }

    struct SampleError: Error, Equatable {}

    @Test func operationErrorPropagates() async {
        // Operation throws first → its own error, not TimeoutError.
        await #expect(throws: SampleError.self) {
            try await withTimeout(.seconds(1), sleep: { _ in
                try await Task.sleep(for: .seconds(1000))
            }, operation: { throw SampleError() })
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Delegate to the `apple-platform-build-tools:builder` agent: run the AuraKit test target filtered to `WithTimeoutTests`.
Expected: FAIL — `withTimeout` / `TimeoutError` not defined.

- [ ] **Step 3: Write the implementation**

Create `AuraCore/Sources/AuraKit/GroupRide/Timeout.swift`:

```swift
import Foundation

/// Thrown by `withTimeout` when the timeout elapses before `operation` finishes.
struct TimeoutError: Error, Equatable {}

/// Runs `operation`, racing it against `sleep(duration)`. Whichever finishes first wins;
/// the loser is cancelled. Throws `TimeoutError` if the sleep wins, or rethrows the
/// operation's own error if it throws first. Fully structured — no unstructured Task
/// escapes this call. `sleep` is injected so tests drive the race deterministically.
func withTimeout<T: Sendable>(
    _ duration: Duration,
    sleep: @Sendable @escaping (Duration) async throws -> Void,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await sleep(duration)
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        return try await group.next()!   // exactly two children added; next() is never nil here
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Delegate to the builder agent: run `WithTimeoutTests`.
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/GroupRide/Timeout.swift AuraCore/Tests/AuraKitTests/GroupRide/GroupRideEndTimeoutTests.swift
git commit -m "feat(group): withTimeout helper racing an injected sleep (ROH-81)"
```

---

## Task 2: Session intent + timeout core

**Files:**
- Modify: `AuraCore/Sources/AuraKit/GroupRide/GroupRideSession.swift`
- Modify: `AuraCore/Sources/AuraKit/GroupRide/InMemoryGroupRideBackend.swift`
- Test: `AuraCore/Tests/AuraKitTests/GroupRide/GroupRideEndTimeoutTests.swift`

**Interfaces:**
- Consumes: `withTimeout` / `TimeoutError` (Task 1).
- Produces:
  - `public enum FinishIntent: Sendable, Equatable { case hostEnd, memberEnd, memberLeave }`
  - `public private(set) var isEnding: Bool`
  - `public func end() async` (→ `.hostEnd`), `public func endAsMember() async` (→ `.memberEnd`), `public func leave() async` (→ `.memberLeave`)
  - `init(..., endTimeout: Duration = .seconds(4), sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) })`
  - InMemory hooks (on `Store`): `var hangEndLeave: Bool`, `var onEndLeaveEntered: (@Sendable () -> Void)?`, `var endLeaveCallCount: Int`

- [ ] **Step 1: Add the InMemory test hooks (infra first)**

In `AuraCore/Sources/AuraKit/GroupRide/InMemoryGroupRideBackend.swift`, add to the `Store` class (alongside the existing spies like `leaveCalled`, `forceEndError`):

```swift
        var hangEndLeave = false                          // test spy: park endRide/leaveRide until cancelled
        var onEndLeaveEntered: (@Sendable () -> Void)?     // test spy: fired when end/leave is entered
        var endLeaveCallCount = 0                          // test spy: how many times end/leave ran
```

Then gate them at the TOP of both `endRide` and `leaveRide` (before the existing body). For `endRide`:

```swift
    public func endRide(rideID: UUID) async throws {
        store.endLeaveCallCount += 1
        store.onEndLeaveEntered?()
        if store.hangEndLeave { try await Task.sleep(for: .seconds(1000)) }
        if let forced = store.forceEndError { store.forceEndError = nil; throw forced }
        // …existing host-check + status flip unchanged…
```

For `leaveRide` (it has no `forceEndError`; keep its existing body after the gate):

```swift
    public func leaveRide(rideID: UUID) async throws {
        store.endLeaveCallCount += 1
        store.onEndLeaveEntered?()
        if store.hangEndLeave { try await Task.sleep(for: .seconds(1000)) }
        guard let uid = store.lock.withLock({ store.currentUserID }) else { throw GroupRideError.notAuthenticated }
        store.members[rideID]?.removeAll { $0 == uid }
        store.leaveCalled = true
    }
```

(No test to run yet — this is shared infra used by the steps below. It compiles as part of Step 3's build.)

- [ ] **Step 2: Write the failing tests**

Append to `GroupRideEndTimeoutTests.swift`. First a small deterministic gate helper and a session factory:

```swift
import AuraCore

/// A one-shot async gate: `wait()` suspends until `open()` is called (once).
final class AsyncGate: @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    private let lock = NSLock()
    func wait() async {
        await withCheckedContinuation { c in
            lock.lock()
            if opened { lock.unlock(); c.resume(); return }
            continuation = c
            lock.unlock()
        }
    }
    func open() {
        lock.lock(); opened = true; let c = continuation; continuation = nil; lock.unlock()
        c?.resume()
    }
}

@MainActor
struct GroupRideEndTimeoutTests {
    private func route() -> Route {
        Route(origin: .init(latitude: 0, longitude: 0), destination: .init(latitude: 1, longitude: 1),
              waypoints: [], geometry: [.init(latitude: 0, longitude: 0), .init(latitude: 1, longitude: 1)],
              profile: .fastest, distanceMeters: 100, estimatedDurationSeconds: 60, elevationGainMeters: 0)
    }

    /// A host session already advanced to `.riding`, with the given seams injected.
    private func ridingHost(
        endTimeout: Duration = .seconds(4),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
    ) async throws -> (GroupRideSession, InMemoryGroupRideBackend) {
        let backend = InMemoryGroupRideBackend()
        try await backend.signIn(idToken: "t", nonce: "n", displayName: "Mike")
        let s = GroupRideSession(backend: backend, transport: InMemoryRideSessionTransport(),
                                 displayNameProvider: { "Mike" }, endTimeout: endTimeout, sleep: sleep)
        await s.create(route: route())
        await s.startRiding()
        #expect(s.phase == .riding)
        return (s, backend)
    }

    @Test func hostEndTimeoutSetsEndFailedAndKeepsRiding() async throws {
        // Injected sleep is instant ({ _ in }); the parked backend loses the race → TimeoutError.
        let (s, backend) = try await ridingHost()
        backend.store.hangEndLeave = true
        await s.end()
        #expect(s.endFailed == true)
        #expect(s.phase == .riding)     // chrome kept
        #expect(s.isEnding == false)    // cleared at rest
    }

    @Test func hostEndTimeoutThenRetryReattempts() async throws {
        let (s, backend) = try await ridingHost()
        backend.store.hangEndLeave = true
        await s.end()
        #expect(s.endFailed == true)
        backend.store.hangEndLeave = false             // signal restored
        await s.retryEndIfNeeded()
        #expect(s.phase == .ended)                     // second attempt succeeds
    }

    @Test func memberEndTimeoutSetsEndFailed() async throws {
        let (s, backend) = try await ridingHost()
        backend.store.hangEndLeave = true
        await s.endAsMember()
        #expect(s.endFailed == true)
        #expect(s.isEnding == false)
    }

    @Test func memberLeaveTimeoutShowsNoFeedback() async throws {
        // The Critical-fix lock: keep-riding leave never surfaces a chip/pending state.
        let (s, backend) = try await ridingHost()
        backend.store.hangEndLeave = true
        await s.leave()
        #expect(s.endFailed == false)
        #expect(s.isEnding == false)
        #expect(s.phase == .riding)     // still riding; no yank affordance
    }

    @Test func isEndingIsTrueWhileInFlight() async throws {
        // Non-instant sleep so the timeout doesn't fire; entry signal proves isEnding was set.
        let entered = AsyncGate()
        let (s, backend) = try await ridingHost(
            sleep: { _ in try await Task.sleep(for: .seconds(1000)) })
        backend.store.hangEndLeave = true
        backend.store.onEndLeaveEntered = { entered.open() }
        let task = Task { await s.end() }
        await entered.wait()            // deterministic: endRide entered → isEnding already set
        #expect(s.isEnding == true)
        task.cancel()
    }

    @Test func doubleEndInvokesBackendOnce() async throws {
        // Re-entrancy guard: a second waited-on end while one is in flight is a no-op.
        let entered = AsyncGate()
        let (s, backend) = try await ridingHost(
            sleep: { _ in try await Task.sleep(for: .seconds(1000)) })
        backend.store.hangEndLeave = true
        backend.store.onEndLeaveEntered = { entered.open() }
        let first = Task { await s.end() }
        await entered.wait()
        await s.end()                   // re-entrant call — guarded out
        #expect(backend.store.endLeaveCallCount == 1)
        first.cancel()
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Delegate to the builder agent: run `GroupRideEndTimeoutTests`.
Expected: FAIL — `endAsMember`, `isEnding`, the `endTimeout`/`sleep` init params don't exist yet.

- [ ] **Step 4: Implement the session changes**

In `GroupRideSession.swift`:

(a) Add the intent enum near `Phase`:

```swift
    /// Which end/leave the caller intends — drives whether the rider waits on it (and sees
    /// pending/timeout feedback) or it's fire-and-forget (keep-riding leave).
    public enum FinishIntent: Sendable, Equatable { case hostEnd, memberEnd, memberLeave }
```

(b) Add observable state near `endFailed`:

```swift
    /// True from a waited-on end/leave tap (hostEnd/memberEnd) until it resolves. Drives the
    /// "Ending…" pill and disables the End control. Never set for a keep-riding leave.
    public private(set) var isEnding = false
```

(c) Replace the `isLeaveNotEnd` stored prop with the remembered intent:

```swift
    private var finishIntent: FinishIntent = .hostEnd
```
(Delete `private var isLeaveNotEnd = false`.)

(d) Add the two seams as stored props and defaulted init params. Change the `init` from:

```swift
    public init(backend: any GroupRideBackend, transport: any RideSessionTransport,
                displayNameProvider: @escaping @Sendable () -> String, cadence: LiveShareCadence = .init()) {
        self.backend = backend
        self.transport = transport
        self.displayNameProvider = displayNameProvider
        self.cadence = cadence
    }
```
to:

```swift
    private let endTimeout: Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(backend: any GroupRideBackend, transport: any RideSessionTransport,
                displayNameProvider: @escaping @Sendable () -> String, cadence: LiveShareCadence = .init(),
                endTimeout: Duration = .seconds(4),
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.backend = backend
        self.transport = transport
        self.displayNameProvider = displayNameProvider
        self.cadence = cadence
        self.endTimeout = endTimeout
        self.sleep = sleep
    }
```

(e) Replace the public `end()`/`leave()` and the `finishRide`/`retryEndIfNeeded` block:

```swift
    public func end() async { await finishRide(.hostEnd) }

    public func endAsMember() async { await finishRide(.memberEnd) }

    public func leave() async { await finishRide(.memberLeave) }

    /// Ends (host) or leaves (member) the ride without ever faking success. `.ended` is set only
    /// when the server confirms, or when the server says the caller is already gone
    /// (`.notHost`/`.notMember`). Waited-on paths (`.hostEnd`/`.memberEnd`) show a pending state
    /// and, on a hang past `endTimeout` or any transient throw, surface `endFailed` (the Retry
    /// chip) while keeping the chrome. A keep-riding leave (`.memberLeave`) is fire-and-forget:
    /// no pending state, no chip — the rider keeps navigating solo regardless (D10).
    private func finishRide(_ intent: FinishIntent) async {
        guard let rideID else { phase = .ended; teardownLive(rideSession); return }
        let leaveOnly = (intent != .hostEnd)
        let showsFeedback = (intent != .memberLeave)
        if showsFeedback, isEnding { return }   // re-entrancy guard for waited-on paths
        finishIntent = intent
        if showsFeedback { endFailed = false; isEnding = true }
        defer { if showsFeedback { isEnding = false } }
        do {
            try await withTimeout(endTimeout, sleep: sleep) { [backend] in
                if leaveOnly { try await backend.leaveRide(rideID: rideID) }
                else         { try await backend.endRide(rideID: rideID) }
            }
            phase = .ended
            teardownLive(rideSession)
        } catch GroupRideError.notHost, GroupRideError.notMember {
            phase = .ended
            teardownLive(rideSession)
        } catch {
            // TimeoutError OR any transient throw. Only a waited-on path surfaces a retry, and
            // only if the ride hasn't already ended out from under us (a racing wire `.rideEnded`
            // / reconcile can flip `.ended` while we were suspended — don't relatch).
            if showsFeedback, phase != .ended {
                endFailed = true
                pendingEnd = true
            }
        }
    }

    /// Re-attempts a pending waited-on end/leave, replaying the same intent.
    public func retryEndIfNeeded() async {
        guard pendingEnd else { return }
        pendingEnd = false
        await finishRide(finishIntent)
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Delegate to the builder agent: run `GroupRideEndTimeoutTests` and `WithTimeoutTests`.
Expected: PASS (all).

- [ ] **Step 6: Commit**

```bash
git add AuraCore/Sources/AuraKit/GroupRide/GroupRideSession.swift AuraCore/Sources/AuraKit/GroupRide/InMemoryGroupRideBackend.swift AuraCore/Tests/AuraKitTests/GroupRide/GroupRideEndTimeoutTests.swift
git commit -m "feat(group): intent-scoped Ending state + 4s end/leave timeout (ROH-81)"
```

---

## Task 3: teardownLive latch-clearing + racing `.rideEnded` guard

**Files:**
- Modify: `AuraCore/Sources/AuraKit/GroupRide/GroupRideSession.swift`
- Test: `AuraCore/Tests/AuraKitTests/GroupRide/GroupRideEndTimeoutTests.swift`

**Interfaces:**
- Consumes: `finishRide`, `teardownLive`, `ingest(.rideEnded)` (existing).
- Produces: no new symbols — behavior only (dissolve clears `endFailed`/`pendingEnd`/`isEnding`).

- [ ] **Step 1: Write the failing test**

Append to `GroupRideEndTimeoutTests`:

```swift
    @Test func racingRideEndedDuringHangLeavesNoStaleLatch() async throws {
        // End is in flight (parked); a wire .rideEnded flips .ended before the timeout resolves.
        // The eventual timeout must NOT relatch endFailed, and no pending latch survives.
        let timeoutGate = AsyncGate()
        let entered = AsyncGate()
        let (s, backend) = try await ridingHost(sleep: { _ in await timeoutGate.wait() })
        backend.store.hangEndLeave = true
        backend.store.onEndLeaveEntered = { entered.open() }
        let task = Task { await s.end() }
        await entered.wait()                 // end() is in flight; isEnding == true, phase == .riding
        await s.ingest(.rideEnded)           // wire signal → phase = .ended, teardownLive clears latches
        #expect(s.phase == .ended)
        timeoutGate.open()                   // now let the timeout fire; catch sees phase == .ended
        await task.value
        #expect(s.endFailed == false)
        #expect(s.isEnding == false)
        await s.retryEndIfNeeded()           // pendingEnd cleared → no re-hit
        #expect(backend.store.endLeaveCallCount == 1)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Delegate to the builder agent: run `GroupRideEndTimeoutTests/racingRideEndedDuringHangLeavesNoStaleLatch`.
Expected: FAIL — `teardownLive` does not yet clear the latches (a stale `endFailed`/`pendingEnd` remains, or the retry re-hits the backend making `endLeaveCallCount == 2`).

- [ ] **Step 3: Implement the latch-clear**

In `GroupRideSession.swift`, add the three resets to the TOP of `teardownLive`:

```swift
    private func teardownLive(_ session: RideSession?) {
        endFailed = false
        pendingEnd = false
        isEnding = false
        session?.stop()
        eventLoopTask?.cancel()
        eventLoopTask = nil
        tickerTask?.cancel()
        tickerTask = nil
        didBeginLive = false
    }
```

(The `catch`'s `phase != .ended` guard added in Task 2 is the other half; this test exercises both together.)

- [ ] **Step 4: Run test to verify it passes**

Delegate to the builder agent: run `GroupRideEndTimeoutTests`.
Expected: PASS.

- [ ] **Step 5: Run the full AuraKit suite (regression)**

Delegate to the builder agent: run the entire AuraKit test target.
Expected: PASS — all pre-existing tests (e.g. `GroupRideSessionLifecycleSyncTests` `end()`/`endFailed`/`retryEndIfNeeded`, `GroupRideSessionTickTests`) still green; default 4s + instant in-memory fake means the operation always wins.

- [ ] **Step 6: Commit**

```bash
git add AuraCore/Sources/AuraKit/GroupRide/GroupRideSession.swift AuraCore/Tests/AuraKitTests/GroupRide/GroupRideEndTimeoutTests.swift
git commit -m "fix(group): clear end/leave latches on dissolve; no stale chip after wire-end (ROH-81)"
```

---

## Task 4: App wiring — pill, disabled End, member-end split, haptic, VoiceOver

**Files:**
- Modify: `Aura/Sources/Ride/ControlCluster.swift`
- Modify: `Aura/Sources/Ride/NavigateHUDView+GroupCrew.swift`
- Modify: `Aura/Sources/Ride/NavigateHUDView.swift`

**Interfaces:**
- Consumes: `groupSession.isEnding`, `groupSession.endFailed`, `groupSession.endAsMember()` (Task 2).
- Produces: `endingPill` view; `ControlCluster(isEndDisabled:)` param.

No AuraKit unit tests here (app-target UI); verified by a clean build (builder agent) and on-device.

- [ ] **Step 1: Add the `isEndDisabled` param to `ControlCluster`**

In `Aura/Sources/Ride/ControlCluster.swift`, add a defaulted property (near `var onEndRide: () -> Void`):

```swift
    /// Disables the End (stop) button while a waited-on group end/leave is pending, so repeated
    /// taps do nothing. Defaulted so the solo/Explore call sites are unaffected.
    var isEndDisabled: Bool = false
```

And apply it to the End button (the `Button(action: onEndRide)` near line 55):

```swift
            Button(action: onEndRide) {
                // …existing label…
            }
            .disabled(isEndDisabled)
```

- [ ] **Step 2: Add `endingPill` and split the member-end call**

In `Aura/Sources/Ride/NavigateHUDView+GroupCrew.swift`, add `endingPill` next to `reconnectingPill`:

```swift
    /// Immediate acknowledgment that a waited-on end/leave is in flight (ROH-81). Styled
    /// identically to `reconnectingPill`/`endFailedPill` so the crew chrome reads as one family.
    /// Only shown for host-end / member-end (a keep-riding leave never sets `isEnding`), so the
    /// "Ending…" wording is always accurate.
    var endingPill: some View {
        HStack(spacing: AuraTheme.Spacing.sm) {
            ProgressView().controlSize(.small).tint(AuraTheme.accent)
            Text("Ending…")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AuraTheme.textPrimary)
        }
        .padding(.horizontal, AuraTheme.Spacing.md)
        .padding(.vertical, AuraTheme.Spacing.sm)
        .background(AuraTheme.surface.opacity(0.9), in: Capsule())
        .overlay(Capsule().strokeBorder(AuraTheme.border))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ending the group ride")
    }
```

Change `endRideAsMember()` to call the new member-end method (was `leave()`):

```swift
    func endRideAsMember() {
        Task {
            await groupSession?.endAsMember()
            if groupSession?.phase == .ended { endRide() }
        }
    }
```

(`leaveCrewKeepRiding()` and `endGroupRideAsHost()` are unchanged — they keep `leave()` / `end()`.)

- [ ] **Step 3: Render the pill, disable End, add haptic + VoiceOver**

In `Aura/Sources/Ride/NavigateHUDView.swift`:

(a) In the top-overlay `VStack` that stacks the status pills (currently `reconnectingPill` + `endFailedPill`, ~lines 101-113), add the ending pill first:

```swift
                VStack(spacing: AuraTheme.Spacing.sm) {
                    if groupSession.isEnding {
                        endingPill
                    }
                    if !groupSession.isLive {
                        reconnectingPill
                    }
                    if groupSession.endFailed {
                        endFailedPill
                    }
                }
                .padding(.top, 44)
```

(b) Pass `isEndDisabled` into the `ControlCluster` in `bottomCockpit` (the private extension, ~line 388):

```swift
                ControlCluster(
                    isFollowing: viewport.followPuck != nil,
                    isMuted: isMuted,
                    onRecenter: { recenter() },
                    onMarkSpot: nil,
                    onToggleMute: { toggleMute() },
                    onEndRide: { onEndTapped() },
                    isEndDisabled: groupSession?.isEnding == true)
```

(c) Add failure haptic + VoiceOver announcements. Attach these modifiers to the main `body` `ZStack` (place them near the other `.onChange` modifiers, e.g. after the `.alert`/`.confirmationDialog` block). Import UIKit at the top of the file if not already imported.

```swift
        .onChange(of: groupSession?.isEnding) { _, isEnding in
            if isEnding == true {
                AccessibilityNotification.Announcement("Ending the group ride").post()
            }
        }
        .onChange(of: groupSession?.endFailed) { _, failed in
            if failed == true {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                AccessibilityNotification.Announcement("Couldn't end the group ride. Retry available.").post()
            }
        }
```

- [ ] **Step 4: Build the app + AuraWidgets**

Delegate to the `apple-platform-build-tools:builder` agent: build the `Aura` app scheme (and AuraWidgets) for the simulator.
Expected: BUILD SUCCEEDED. If `AccessibilityNotification` / `UINotificationFeedbackGenerator` need an import, add `import UIKit` / `import SwiftUI` as required and rebuild.

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/Ride/ControlCluster.swift Aura/Sources/Ride/NavigateHUDView+GroupCrew.swift Aura/Sources/Ride/NavigateHUDView.swift
git commit -m "feat(group): Ending… pill, disabled End, member-end split, failure haptic + VoiceOver (ROH-81)"
```

---

## Task 5: Final verification gate

**Files:** none (verification only).

- [ ] **Step 1: Full AuraKit test suite**

Delegate to the builder agent: run the entire AuraKit test target.
Expected: PASS (all, including the new timeout/leave/latch tests).

- [ ] **Step 2: SwiftLint strict**

Run: `swiftlint --strict` at repo root (or the project's configured lint invocation).
Expected: no violations. Fix any inline (e.g. line length on the new comments) and re-run.

- [ ] **Step 3: App + widgets build**

Delegate to the builder agent: build `Aura` + `AuraWidgets` for the simulator.
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Confirm no stray `isLeaveNotEnd` references**

Run: `grep -rn "isLeaveNotEnd" AuraCore Aura`
Expected: no matches (renamed to `finishIntent`).

---

## Self-Review (author checklist — completed)

- **Spec coverage:** Goals 1-4 → pill (Task 4) / timeout (Tasks 1-2) / tests (Tasks 1-3) / member-leave scoping (Task 2, `memberLeaveTimeoutShowsNoFeedback`). Re-entrancy guard, latch-clear, racing-`.rideEnded` guard, haptic, VoiceOver, `endAsMember` split all mapped to tasks. Cancellation caveat is a device-verify item (Verification, not code).
- **Placeholder scan:** none — every code step shows complete code and exact commands.
- **Type consistency:** `FinishIntent`/`finishIntent`/`endAsMember`/`isEnding`/`endTimeout`/`sleep`/`isEndDisabled`/`hangEndLeave`/`onEndLeaveEntered`/`endLeaveCallCount` used identically across tasks. `retryEndIfNeeded` replays `finishIntent`. `endFailed`/`pendingEnd`/`phase`/`teardownLive` match the existing source.
- **Note:** if `withTimeout`/`TimeoutError` trip SwiftLint on being unused-internal or file header conventions, keep them `internal` (used by `finishRide`) — they are referenced, so no unused warning. The `@unchecked Sendable` `AsyncGate` is test-only.
