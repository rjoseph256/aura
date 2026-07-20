# ROH-81 — Group-ride End/Leave feedback while the network hangs

**Status:** approved (2026-07-19)
**Linear:** ROH-81 (Group Rides Tail, High) — follow-up from single-phone device-verify of ROH-68.
**Related:** ROH-68 (the silent-failure fix, done), ROH-79 (end/leave retry polish incl. deferred auto-backoff timer).

## Problem

When a host taps **End for everyone** under a hung network (airplane mode), `GroupRideSession.finishRide`
awaits `backend.endRide` with **no timeout**. Airplane mode does not throw quickly — the request hangs on
a network timeout (tens of seconds), so `finishRide`'s `catch` never fires promptly, `endFailed` is never
set, and the existing "Couldn't end — Retry" chip (`endFailedPill`) never appears. The host sees a
frozen-looking screen with zero feedback and taps End repeatedly.

This is **not** a recurrence of the ROH-68 silent-failure bug — that fix holds (no false success, no
stranded ride; the ride ends cleanly once signal returns). This is purely a **missing-feedback gap during
the hang**. It is the test-blind-spot class from the ROH-68 whole-branch review's C1 finding: the in-memory
fake throws instantly, so a hang has no coverage today.

## Goals

1. Acknowledge the tap immediately with an on-theme **"Ending…" pending state**, and stop the repeat-tap loop.
2. Bound the end/leave call with a short **timeout (4s)**; on timeout, surface the existing Retry chip.
3. Add AuraKit coverage for the **timeout → `endFailed`** path (closes the hang blind spot).

## Non-goals

- The lobby **Start ride** call has the identical hang gap (`startFailed` only fires on a throw). **Out of
  scope** for ROH-81 — it already has `startFailed`/Retry lobby infra; file a separate small follow-up if
  wanted. This spec keeps the change tight to the device-verified End/Leave finding.
- The **auto-backoff retry timer** (2s/4s/8s) stays deferred to ROH-79. ROH-81 keeps the retry manual (the
  chip's Retry button + `retryEndIfNeeded()`), exactly as ROH-68 shipped.

## Design

### Layer 1 — AuraKit `GroupRideSession` (the testable core)

All timing logic lives here (not in the Supabase conformer) so it is deterministically unit-testable — the
same reason the ticket calls for AuraKit coverage.

**New observable state**
```swift
/// True from the moment an end()/leave() is tapped until it resolves (server-confirmed,
/// already-gone, or timed-out/failed). Drives the "Ending…" pill and disables the End control
/// so repeated taps during a hang do nothing.
public private(set) var isEnding = false
```

**New injected seams on `init` (both defaulted, so no production call-site change is required):**
```swift
endTimeout: Duration = .seconds(4)
sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
```
Production gets 4s + real `Task.sleep` automatically. Tests inject a tiny/instant `sleep` and a hanging
backend to drive the timeout branch deterministically (no real wall-clock wait, no leaked Tasks — the
concern that deferred the auto-backoff timer does not apply here because the seam is injected).

**New internal timeout helper** (new file `AuraCore/Sources/AuraKit/GroupRide/Timeout.swift`):
```swift
struct TimeoutError: Error, Equatable {}

/// Runs `operation`, racing it against `sleep(duration)`. Whichever finishes first wins; the
/// loser is cancelled. Throws `TimeoutError` if the sleep wins. Structured — no unstructured
/// Task escapes this call.
func withTimeout<T: Sendable>(
    _ duration: Duration,
    sleep: @Sendable @escaping (Duration) async throws -> Void,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask { try await sleep(duration); throw TimeoutError() }
        defer { group.cancelAll() }
        return try await group.next()!   // first child to finish (value, its throw, or TimeoutError)
    }
}
```

**`finishRide` change** (the only behavioral edit to the reducer):
```swift
private func finishRide(leaveOnly: Bool) async {
    guard let rideID else { phase = .ended; teardownLive(rideSession); return }
    endFailed = false
    isEnding = true
    isLeaveNotEnd = leaveOnly
    defer { isEnding = false }
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
        // TimeoutError OR any transient network throw — keep the chrome, surface the Retry chip.
        endFailed = true
        pendingEnd = true
    }
}
```

- `isEnding = true` is set **synchronously before the first `await`** (this func is `@MainActor`), so SwiftUI
  paints the pending state on the same run loop as the tap.
- The `defer` flips `isEnding = false` as the sync tail runs — after `phase`/`endFailed` are already set, so
  SwiftUI coalesces to one repaint with no intermediate frame where nothing is showing.
- The operation closure captures `[backend]` (Sendable) + local `rideID`/`leaveOnly` only — never `self`
  (which is `@MainActor`, non-Sendable). This keeps the child tasks Sendable-clean.

**Outcome table**

| Case | Result | Changed? |
|------|--------|----------|
| Success | `.ended`, teardown | no |
| `notHost` / `notMember` (already gone / lost-response retry) | `.ended`, teardown | no (ROH-68) |
| Fast transient throw | `endFailed`, keep `.riding` | no (ROH-68) |
| **Hang past 4s → `TimeoutError`** | **`endFailed`, keep `.riding` → Retry chip** | **NEW** |

Idempotency makes the timeout safe: `end_ride`/`leave_ride` are idempotent, so a request that lands
server-side *after* the client timed out is harmless, and the subsequent Retry hits `notHost`/`notMember`
→ treated as success → converges to `.ended`. `retryEndIfNeeded()` re-runs `finishRide`, so retry also gets
the pending state + timeout for free.

**Cancellation caveat (verify on device):** the ~4s Retry timing depends on the backend call honoring
`Task` cancellation. supabase-swift issues its RPC over `URLSession`, whose async APIs throw on
cancellation, so `cancelAll()` unblocks the group promptly. If a conformer ever ignored cancellation, the
group would await the still-hanging child and the pill would linger past 4s before the chip — still a strict
improvement over the frozen screen, but the on-device airplane-mode test is what confirms the 4s path. The
in-memory hanging fake uses `Task.sleep` (cancellation-aware), so the unit test is deterministic regardless.

### Layer 2 — App wiring (`Aura/Sources/Ride/`)

**`NavigateHUDView+GroupCrew.swift` — new `endingPill`**, styled identically to `reconnectingPill` /
`endFailedPill` (same capsule, `AuraTheme.surface.opacity(0.9)`, border, tokens) so the crew chrome reads as
one status-pill family:
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
(Member-leave shows the same pill; "Ending…" reads correctly for both End and Leave. A leave-specific label
is not worth a branch here.)

**`NavigateHUDView.swift`**
- In the existing top-overlay `VStack` (the one that stacks `reconnectingPill` + `endFailedPill`), render
  `endingPill` when `groupSession.isEnding`. In practice `isEnding` and `endFailed` are mutually exclusive
  (`endFailed` is only set after `isEnding` clears), so at most one pill shows; the VStack handles all cases
  defensively.
- Disable the End control while `isEnding`: pass a new `isEndDisabled: Bool = false` param (defaulted, so the
  solo/Explore call sites are untouched) into `ControlCluster`, wired as `groupSession?.isEnding == true`,
  and apply `.disabled(isEndDisabled)` to the End `Button` in `ControlCluster.swift`. This dims the control
  and, together with the confirmation dialog dismissing on selection, ends the tap-repeatedly loop. (Guarding
  `onEndTapped()` is a belt-and-suspenders no-op we skip; the disabled control is the affordance.)

**Production construction:** because both new `init` params are defaulted, the app's `GroupRideSession`
construction site needs **no change** — it inherits 4s + real `Task.sleep`.

### Tests (AuraKit, Swift Testing)

New coverage under `AuraCore/Tests/AuraKitTests/GroupRide/`:

1. **`withTimeout` unit tests** — operation-wins returns its value; timeout-wins throws `TimeoutError`;
   an operation that throws propagates its own error (not `TimeoutError`).
2. **End timeout → `endFailed`** — a **hanging backend fake** (`endRide`/`leaveRide` do
   `try await Task.sleep(for: .seconds(1000))`) + injected `sleep: { _ in }` so the timeout child wins
   immediately. Drive `await session.end()`; assert `endFailed == true`, `phase == .riding` (chrome kept),
   `isEnding == false` at rest, and that `retryEndIfNeeded()` re-attempts (via `pendingEnd`).
3. **Leave timeout → `endFailed`** — same via `await session.leave()` with `isLeaveNotEnd` retained.
4. **`isEnding` is set during flight** — start `Task { await session.end() }` against the hanging fake with a
   *real* (non-instant) injected sleep, `await Task.yield()`, assert `isEnding == true` before releasing the
   hang. (Deterministic via the hanging fake; exact mechanism finalized in the plan.)
5. **Regression** — existing lifecycle/end tests still pass unchanged: default 4s timeout + the instant
   in-memory fake means the operation always wins the race well under 4s, so behavior is identical.

## Files touched

| File | Change |
|------|--------|
| `AuraCore/Sources/AuraKit/GroupRide/Timeout.swift` | **new** — `withTimeout` + `TimeoutError` (internal) |
| `AuraCore/Sources/AuraKit/GroupRide/GroupRideSession.swift` | add `isEnding`, `endTimeout`/`sleep` seams, wrap `finishRide` |
| `Aura/Sources/Ride/NavigateHUDView+GroupCrew.swift` | new `endingPill` |
| `Aura/Sources/Ride/NavigateHUDView.swift` | render `endingPill`; pass `isEndDisabled` |
| `Aura/Sources/Ride/ControlCluster.swift` | new defaulted `isEndDisabled` param on the End button |
| `AuraCore/Tests/AuraKitTests/GroupRide/…` | new timeout/pending-state tests + hanging fake |

## Verification

- `swift test` (AuraKit) green, including the new timeout tests; `swiftlint --strict` clean; Aura app +
  AuraWidgets build.
- **On-device (single iPhone) — the closing check:** enable airplane mode mid group-ride, tap End →
  "Ending…" pill appears immediately → after ~4s the "Couldn't end — Retry" chip appears; the End control is
  disabled while pending; restoring signal + Retry ends the ride cleanly into the summary.
