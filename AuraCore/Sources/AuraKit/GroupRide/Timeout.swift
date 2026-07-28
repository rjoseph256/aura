import Foundation

/// Thrown by `withTimeout` when the timeout elapses before `operation` finishes.
struct TimeoutError: Error, Equatable {}

/// Runs `operation`, bounded by `sleep(duration)`. If the operation finishes first, its value
/// (or its thrown error) is returned. If the timeout fires first, the operation is cancelled and
/// `TimeoutError` is thrown. Outer cancellation propagates to the operation (no leaked work).
///
/// `sleep` is injected so tests drive the race deterministically.
///
/// **Structured on purpose (ROH-110).** Both tasks are children of a task group, so the group
/// cannot return until both have finished — the loser is cancelled by `cancelAll` and awaited on
/// the way out. Nothing outlives the call.
///
/// This function previously raced two unstructured `Task`s and *deliberately left the timeout
/// task uncancelled on the success path*, to dodge an abort inside the task allocator. That
/// traded a crash for a leak and made the crash worse: every successful call left a timer parked
/// for the full `duration` (4s for a group-ride end), which then woke up inside whatever
/// unrelated code was running by then. In the test process — a ~4s run — those wakeups landed
/// mid-suite and aborted it about 30% of the time, which is the bug ROH-110 was chasing through
/// SwiftData for two sessions. The crash was never in SwiftData; the leaked timer was carrying it.
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
        // Whichever finishes first decides the call; the other is cancelled and awaited by the
        // group before it returns. A cancelled `sleep` throws, but that result is never read.
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw TimeoutError() }
        return first
    }
}
