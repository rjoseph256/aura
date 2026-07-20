# ROH-81 — Group-ride End/Leave feedback while the network hangs

**Status:** approved + reconciled against adversarial spec review (2026-07-19)
**Linear:** ROH-81 (Group Rides Tail, High) — follow-up from single-phone device-verify of ROH-68.
**Related:** ROH-68 (the silent-failure fix, done), ROH-79 (end/leave retry polish incl. deferred auto-backoff timer).

## Problem

When a host taps **End for everyone** under a hung network (airplane mode), `GroupRideSession.finishRide`
awaits `backend.endRide` with **no timeout**. Airplane mode does not throw quickly — the request hangs on a
network timeout (tens of seconds), so `finishRide`'s `catch` never fires promptly, `endFailed` is never set,
and the existing "Couldn't end — Retry" chip (`endFailedPill`) never appears. The host sees a frozen-looking
screen with zero feedback and taps End repeatedly.

This is **not** a recurrence of the ROH-68 silent-failure bug — that fix holds (no false success, no stranded
ride; the ride ends cleanly once signal returns). This is purely a **missing-feedback gap during the hang**.
It is the test-blind-spot class from ROH-68's whole-branch review C1: the in-memory fake throws instantly, so
a hang has no coverage today.

## Goals

1. Acknowledge the tap immediately with an on-theme **"Ending…" pending state**, and stop the repeat-tap loop.
2. Bound the end/leave call with a short **timeout (4s)**; on timeout, surface the existing Retry chip.
3. Add AuraKit coverage for the **timeout → `endFailed`** path (closes the hang blind spot).
4. Do all of the above **without misfiring on the member "Leave crew, keep riding" path** (see Design §3).

## Non-goals

- The lobby **Start ride** call has the identical hang gap (`startFailed` only fires on a throw). **Out of
  scope** for ROH-81 — it already has `startFailed`/Retry lobby infra; file a separate small follow-up if
  wanted.
- The **auto-backoff retry timer** (2s/4s/8s) stays deferred to ROH-79. ROH-81 keeps retry manual (the chip's
  Retry button + `retryEndIfNeeded()`), exactly as ROH-68 shipped.
- **Optimistically dissolving crew chrome on a failed keep-riding leave** is out of scope — that path keeps
  its current behavior unchanged (see §3).

## The three end/leave paths (why intent matters)

All three funnel through `finishRide` today, but they want different feedback:

| # | Trigger | Backend call | Finishes local ride? | Wants pending feedback? |
|---|---------|--------------|----------------------|-------------------------|
| A | Host "End group ride" (`endGroupRideAsHost`) | `endRide` | yes (host + everyone) | **yes** |
| B | Member "Leave crew" keep riding (`leaveCrewKeepRiding`) | `leaveRide` | **no** — keeps navigating solo (D10) | **no** |
| C | Member "End ride" (`endRideAsMember`) | `leaveRide` | yes (self) | **yes** |

The shipped code cannot tell B from C — both call `leave()` → `finishRide(leaveOnly: true)`. That ambiguity
is the root of the review's Critical finding: the shared `endFailedPill` Retry runs `if phase == .ended {
endRide() }`, so under the new 4s timeout a **still-riding** leave-keep-riding member (path B) would get an
"Ending…"/"Couldn't end" chip (both false) and, on Retry, be **yanked into a ride summary they never asked
for**. The fix is to give the session the caller's intent and scope all new feedback to paths A and C only.

## Design

### 1. AuraKit `GroupRideSession` — intent + the testable timeout core

All timing logic lives here (not in the Supabase conformer) so it is deterministically unit-testable.

**New finish intent** replaces the `isLeaveNotEnd: Bool` latch:
```swift
public enum FinishIntent: Sendable, Equatable { case hostEnd, memberEnd, memberLeave }
```
- `end()` → `finishRide(.hostEnd)`
- `endAsMember()` **(new)** → `finishRide(.memberEnd)`
- `leave()` → `finishRide(.memberLeave)`

Two derived flags inside `finishRide`:
- `leaveOnly = (intent != .hostEnd)` — B and C both call `leaveRide`.
- `showsFeedback = (intent != .memberLeave)` — only A and C are ones the rider waits on; B is fire-and-forget.

**New observable state**
```swift
/// True from an end/leave tap that the rider is waiting on (hostEnd/memberEnd) until it resolves.
/// Drives the "Ending…" pill and disables the End control. Never set for a keep-riding leave.
public private(set) var isEnding = false
private var finishIntent: FinishIntent = .hostEnd   // remembered so retryEndIfNeeded replays the same intent
```

**New injected seams on `init` (both defaulted → no production call-site change):**
```swift
endTimeout: Duration = .seconds(4)
sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
```

**New internal timeout helper** (new file `AuraCore/Sources/AuraKit/GroupRide/Timeout.swift`):
```swift
struct TimeoutError: Error, Equatable {}

/// Runs `operation`, racing it against `sleep(duration)`. First to finish wins; the loser is
/// cancelled. Throws `TimeoutError` if the sleep wins; rethrows the operation's own error if it
/// throws first. Structured — no unstructured Task escapes this call.
func withTimeout<T: Sendable>(
    _ duration: Duration,
    sleep: @Sendable @escaping (Duration) async throws -> Void,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask { try await sleep(duration); throw TimeoutError() }
        defer { group.cancelAll() }
        return try await group.next()!   // exactly two children added; next() is never nil here
    }
}
```

**`finishRide` change:**
```swift
private func finishRide(_ intent: FinishIntent) async {
    guard let rideID else { phase = .ended; teardownLive(rideSession); return }
    let leaveOnly = (intent != .hostEnd)
    let showsFeedback = (intent != .memberLeave)
    // Re-entrancy guard: a second waited-on end/leave while one is in flight is a no-op.
    // (Belt-and-suspenders with the disabled End control, and the real guard against the
    //  confirmation dialog's destructive button / a stale Retry firing twice.)
    if showsFeedback, isEnding { return }
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
        // TimeoutError OR any transient throw. Only surface a retry affordance on a waited-on
        // path, and only if the ride hasn't already ended out from under us (a racing wire
        // `.rideEnded` / reconcile can flip `.ended` while we were suspended — don't relatch).
        if showsFeedback, phase != .ended {
            endFailed = true
            pendingEnd = true
        }
    }
}
```

- `isEnding = true` is set **synchronously before the first `await`** (`@MainActor`), so SwiftUI paints the
  pending state on the same run loop as the tap.
- The `defer` flips `isEnding = false` in the sync tail, after `phase`/`endFailed` are set → SwiftUI
  coalesces to one repaint.
- The operation closure captures `[backend]` + local `rideID`/`leaveOnly` only — never `self` (`@MainActor`,
  non-Sendable) — keeping the child tasks Sendable-clean.
- **Path B (memberLeave) is behaviorally unchanged from today:** no `isEnding`, no `endFailed`, no chip. On
  success `phase = .ended` dissolves crew chrome and the rider keeps navigating solo (D10, `endRide()` is
  never called for B). On failure/timeout nothing is surfaced — acceptable, as the existing D10 comment
  states. This also **fixes the pre-existing yank bug** for B (it can no longer reach the `endRide()` Retry).

**Retry replays the same intent:**
```swift
public func retryEndIfNeeded() async {
    guard pendingEnd else { return }
    pendingEnd = false
    await finishRide(finishIntent)   // only ever .hostEnd or .memberEnd (B never sets pendingEnd)
}
```

**`teardownLive` clears the stale latches** so no chip/pending state survives a dissolve by any route (host
end, member leave, wire `.rideEnded`, authoritative reconcile → `.ended`):
```swift
private func teardownLive(_ session: RideSession?) {
    endFailed = false
    pendingEnd = false
    isEnding = false
    // …existing stop/cancel/reset…
}
```
This resolves the review's stray-latch findings: a wire `.rideEnded` that wins the race against an in-flight
end tears down cleanly, and a later `retryEndIfNeeded()` cannot re-hit the backend on an already-ended ride.

**Outcome table (paths A & C — the waited-on ones)**

| Case | Result | Changed? |
|------|--------|----------|
| Success | `.ended`, teardown | no |
| `notHost` / `notMember` (already gone / lost-response retry) | `.ended`, teardown | no (ROH-68) |
| Fast transient throw | `endFailed`, keep `.riding` | no (ROH-68) |
| **Hang past 4s → `TimeoutError`** | **`endFailed`, keep `.riding` → Retry chip** | **NEW** |
| Racing wire `.rideEnded` then our timeout | `.ended` (no stray chip) | **NEW guard** |

Idempotency makes the timeout safe: `end_ride`/`leave_ride` are idempotent, so a request that lands
server-side *after* the client timed out is harmless, and the subsequent Retry hits `notHost`/`notMember` →
success → converges to `.ended`.

**Known convergence gap (accepted, documented):** on a *slow-but-succeeding* network the end can commit
server-side just as the 4s timeout fires; the host then sees "Couldn't end — Retry" for a ride that actually
ended (guests already dissolved). With the auto-backoff timer deferred to ROH-79, recovery is either a manual
Retry (idempotent → converges) or an authoritative `.connected` → `reconcileFromStatus()` reading `endedAt`
→ `.ended` (which now also clears the latches via `teardownLive`). This is the deliberate ROH-81/ROH-79 seam,
not a regression — surfacing a false-negative Retry is strictly better than the frozen screen it replaces.

**Cancellation caveat (verify on device):** `withTimeout` is structured, so the group awaits both children
before returning; `cancelAll()` only *requests* cancellation. supabase-swift issues its RPC over `URLSession`,
whose async APIs throw on cancellation, so the loser unblocks promptly and the chip appears ~4s after the
tap. **If a conformer ever ignored cancellation, `withTimeout` would not return until the OS network stack's
own multi-tens-of-seconds timeout fired — `isEnding` would stay true and the chip would not appear until
then** (i.e. the pill would linger, not "briefly past 4s"). This is a caveat about a hypothetical
non-cooperative backend, not the live one; the on-device airplane-mode test is what confirms the real 4s
path. The unit test's hanging fake uses `Task.sleep` (cancellation-aware), so it is deterministic regardless.

### 2. App wiring (`Aura/Sources/Ride/`)

**`NavigateHUDView+GroupCrew.swift`**
- New `endingPill`, styled identically to `reconnectingPill` / `endFailedPill` (same capsule,
  `AuraTheme.surface.opacity(0.9)`, border, tokens) so the crew chrome reads as one status-pill family:
  ```swift
  var endingPill: some View {
      HStack(spacing: AuraTheme.Spacing.sm) {
          ProgressView().controlSize(.small).tint(AuraTheme.accent)
          Text("Ending…").font(.subheadline.weight(.semibold))
              .foregroundStyle(AuraTheme.textPrimary)
      }
      .padding(.horizontal, AuraTheme.Spacing.md).padding(.vertical, AuraTheme.Spacing.sm)
      .background(AuraTheme.surface.opacity(0.9), in: Capsule())
      .overlay(Capsule().strokeBorder(AuraTheme.border))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Ending the group ride")
  }
  ```
  The copy is honest for every case that shows it: `isEnding` is only ever true for host-end (A) or member-end
  (C), both of which are genuinely ending the ride. A keep-riding leave (B) never shows it, so no "Leaving…"
  branch is needed.
- `endRideAsMember()` now calls `groupSession?.endAsMember()` (was `leave()`); `leaveCrewKeepRiding()` still
  calls `leave()`. `endGroupRideAsHost()` is unchanged (`end()`).

**`NavigateHUDView.swift`**
- In the existing top-overlay `VStack` (the one that stacks `reconnectingPill` + `endFailedPill`), render
  `endingPill` when `groupSession.isEnding`. In practice `isEnding` and `endFailed` are mutually exclusive
  (`endFailed` is only set after `isEnding` clears), so at most one shows; the `VStack` handles it defensively.
- Disable the End control while `isEnding`: pass a new `isEndDisabled: Bool = false` param (defaulted → the
  solo/Explore call sites untouched) into `ControlCluster`, wired `groupSession?.isEnding == true`, applied as
  `.disabled(isEndDisabled)` on the End `Button` in `ControlCluster.swift`. Because `isEnding` is never set for
  a keep-riding leave, a still-riding member's own stop button is **not** dead while they leave the crew
  (resolves the review's "dead stop button" finding).
- **Failure haptic:** `.onChange(of: groupSession?.endFailed)` — when it flips to `true`, fire
  `UINotificationFeedbackGenerator().notificationOccurred(.error)` (app-target UI concern; honors the system
  Haptics setting and no-ops on non-Taptic hardware, like the existing `HapticPlayer`). Gives the host a felt
  signal even though the pill is at the top and their thumb is at the bottom.
- **VoiceOver announcements:** `.onChange(of: groupSession?.isEnding)` → announce "Ending the group ride" when
  it becomes true; `.onChange(of: groupSession?.endFailed)` → announce "Couldn't end the group ride. Retry
  available." when it becomes true, via `AccessibilityNotification.Announcement(_).post()`. A VoiceOver host
  who just confirmed a destructive End now hears the acknowledgment and the failure instead of silence.

**Production construction:** both new `init` params are defaulted, so the app's `GroupRideSession`
construction site needs **no change** — it inherits 4s + real `Task.sleep`.

### 3. Member-leave path summary (explicit, since it's the review's Critical)

After this change, path B (Leave crew, keep riding) is **fully unchanged in behavior** and simply opts out of
all the new machinery: no `isEnding`, no "Ending…" pill, no `endFailed` chip, no disabled stop button, and it
can never reach the `endRide()`-on-`.ended` Retry (there is no chip to tap). The honest copy, the un-yanked
rider, and the live stop button all fall out of "scope feedback to the waited-on paths only."

## Tests (AuraKit, Swift Testing)

New coverage under `AuraCore/Tests/AuraKitTests/GroupRide/`:

1. **`withTimeout` unit tests** — operation-wins returns its value; timeout-wins throws `TimeoutError`; an
   operation that throws first propagates its own error (not `TimeoutError`).
2. **Host-end timeout → `endFailed`** — a **hanging backend fake** (`endRide` does
   `try await Task.sleep(for: .seconds(1000))`) + injected `sleep: { _ in }` so the timeout child wins
   immediately. `await session.end()`; assert `endFailed == true`, `phase == .riding`, `isEnding == false`
   at rest, and `retryEndIfNeeded()` re-attempts (via `pendingEnd`).
3. **Member-end timeout → `endFailed`** — same via `await session.endAsMember()`.
4. **Member-leave (keep riding) timeout → NO feedback** — `await session.leave()` against the hanging fake;
   assert `endFailed == false`, `isEnding == false`, and `pendingEnd`/chip never set (locks the Critical fix).
5. **`isEnding` true during flight (deterministic)** — a backend fake that **signals entry via a
   continuation** the moment `endRide` is called, then parks. The test awaits that signal, asserts
   `isEnding == true`, then releases the park. (No `Task.yield()` guessing — the continuation makes it
   deterministic.)
6. **Stray-latch guard** — drive an in-flight end, deliver a wire `.rideEnded` (→ `phase = .ended`,
   `teardownLive`) before the timeout resolves; assert no `endFailed`/`pendingEnd` remain and `isEnding` is
   false.
7. **Re-entrancy guard** — call `end()` twice without awaiting the first; assert the backend `endRide` is
   invoked once and state stays consistent.
8. **Regression** — existing lifecycle/end tests still pass: default 4s + the instant in-memory fake means
   the operation always wins the race well under 4s, so behavior is identical. (Any existing test referencing
   `isLeaveNotEnd` / a raw `leave()`-then-end for the member-end path is updated to the new intent surface.)

## Files touched

| File | Change |
|------|--------|
| `AuraCore/Sources/AuraKit/GroupRide/Timeout.swift` | **new** — `withTimeout` + `TimeoutError` (internal) |
| `AuraCore/Sources/AuraKit/GroupRide/GroupRideSession.swift` | `FinishIntent`; `end`/`endAsMember`/`leave`; `isEnding`; `endTimeout`/`sleep` seams; rewrite `finishRide`; clear latches in `teardownLive` |
| `Aura/Sources/Ride/NavigateHUDView+GroupCrew.swift` | new `endingPill`; `endRideAsMember` → `endAsMember()` |
| `Aura/Sources/Ride/NavigateHUDView.swift` | render `endingPill`; pass `isEndDisabled`; failure haptic + VoiceOver announcements |
| `Aura/Sources/Ride/ControlCluster.swift` | new defaulted `isEndDisabled` param on the End button |
| `AuraCore/Tests/AuraKitTests/GroupRide/…` | timeout/pending/leave/latch/re-entrancy tests + hanging & signaling fakes |

## Verification

- `swift test` (AuraKit) green, including the new timeout/leave/latch tests; `swiftlint --strict` clean; Aura
  app + AuraWidgets build.
- **On-device (single iPhone) — the closing check:** enable airplane mode mid group-ride, tap End for
  everyone → "Ending…" pill appears immediately + a failure haptic ~4s later → "Couldn't end — Retry" chip
  appears; the End control is disabled while pending; restoring signal + Retry ends the ride cleanly into the
  summary with a clean pill-out → summary-in hand-off (watch for any flash). If feasible, also exercise a
  member "Leave crew" under airplane mode and confirm no "Ending…"/"Couldn't end" chip appears and the stop
  button stays live.
