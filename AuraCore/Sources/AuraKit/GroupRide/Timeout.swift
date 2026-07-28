import Foundation

/// Thrown by `withTimeout` when the timeout elapses before `operation` finishes.
struct TimeoutError: Error, Equatable {}

/// Runs `operation`, bounded by `sleep(duration)`. If the operation finishes first, its value
/// (or its thrown error) is returned. If the timeout fires first, the operation is cancelled and
/// `TimeoutError` is thrown. Outer cancellation propagates to the operation (no leaked work).
///
/// **The operation's own outcome always wins, even after the timer fires.** When the timeout
/// elapses the operation is cancelled, but whatever it then produces is preferred: a success that
/// lands in the cancellation window is a real success, and a real error must reach the caller's
/// `catch` arms. Only a `CancellationError` — the operation giving up because *we* cancelled it —
/// becomes `TimeoutError`. Resolving the race by which child finished first instead would tell a
/// rider "Couldn't end the ride, Retry" about a ride that just ended server-side, and would mask
/// `GroupRideError.notHost`, which `GroupRideSession` treats as success.
///
/// **Both bounds hold only for cancellation-responsive work.** Both legs are children of the
/// group, so the call cannot return until both have finished. An `operation` that ignores
/// cancellation is still awaited, so the wait is its length rather than `duration`; a `sleep`
/// that ignores cancellation blocks the *success* path for the full `duration`. Every caller
/// today is `Task.sleep`- or URLSession-based, and both honour cancellation.
///
/// `sleep` is injected so tests drive the race deterministically. It has no default value on
/// purpose — see the note on `GroupRideSession.sleep` (ROH-110): an `async` closure written as a
/// *default argument* is emitted into the caller's module, and on this toolchain that copy is
/// mis-sized, so freeing its frame aborts the process.
///
/// **Structured on purpose.** The loser is cancelled by `cancelAll` and awaited on the way out,
/// so nothing outlives the call. This replaced a version that raced two unstructured `Task`s and
/// *deliberately left the timeout task uncancelled on the success path* to dodge that abort. It
/// did not work — making the timer structured, on its own, took the abort from intermittent to
/// 20/20 — because the leak only governed *when* the mis-sized frame got freed, never whether it
/// was mis-sized. It also leaked: every successful call left a timer parked for the full
/// `duration` (4s for a group-ride end). Both are gone; the fix for the abort itself is on the
/// two initializers that used to carry an `async` default argument.
func withTimeout<T: Sendable>(
    _ duration: Duration,
    sleep: @Sendable @escaping (Duration) async throws -> Void,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    // The element is `T?` so the timer can report "elapsed" without throwing: a throwing timer
    // would beat a still-running operation to `next()` and mask its result.
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await sleep(duration)
            return nil
        }
        defer { group.cancelAll() }

        // Two children were just added, so `next()` cannot be nil here; the guard is the
        // language's, not a real branch.
        guard let firstOutcome = try await group.next() else { throw TimeoutError() }
        if let value = firstOutcome { return value }

        // The timer won. Cancel the operation, then still take its answer if it has one.
        group.cancelAll()
        do {
            if let lateOutcome = try await group.next(), let value = lateOutcome { return value }
        } catch is CancellationError where !Task.isCancelled {
            // The operation gave up because we cancelled it. That is the timeout.
            throw TimeoutError()
        }
        throw TimeoutError()
    }
}
