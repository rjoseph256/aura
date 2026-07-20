import Foundation

/// Thrown by `withTimeout` when the timeout elapses before `operation` finishes.
struct TimeoutError: Error, Equatable {}

/// Runs `operation`, bounded by `sleep(duration)`. If the operation finishes first, its value
/// (or its thrown error) is returned. If the timeout fires first, the operation is cancelled and
/// `TimeoutError` is thrown. Outer cancellation propagates to the operation (no leaked work).
///
/// Deliberately does NOT cancel the timeout task on the success path. On this toolchain,
/// cancelling a task that is parked inside a real `Task.sleep` as the caller unwinds corrupts
/// the task allocator (`swift_task_dealloc` double-free → SIGABRT) — reproduced identically with
/// both a `withThrowingTaskGroup` race and a fire-and-forget `Task.cancel()`. Instead the timeout
/// task is left to elapse on its own; when it does it cancels an already-finished operation task,
/// which is a no-op. Cost: a successful call leaves a background timer that lingers up to
/// `duration` (≈ the timeout) and then no-ops — harmless. Only the `onCancel` path (outer
/// cancellation, an unwind rather than a return) cancels the tasks, which is safe.
/// `sleep` is injected so tests drive the race deterministically.
func withTimeout<T: Sendable>(
    _ duration: Duration,
    sleep: @Sendable @escaping (Duration) async throws -> Void,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    let operationTask = Task { try await operation() }
    let timeoutTask = Task {
        // A cancelled timer must NOT cancel the operation — only an elapsed one.
        do { try await sleep(duration) } catch { return }
        operationTask.cancel()
    }
    return try await withTaskCancellationHandler {
        do {
            return try await operationTask.value
        } catch is CancellationError where !Task.isCancelled {
            // The operation was cancelled by the elapsed timer (not by our caller).
            throw TimeoutError()
        }
    } onCancel: {
        operationTask.cancel()
        timeoutTask.cancel()
    }
}
