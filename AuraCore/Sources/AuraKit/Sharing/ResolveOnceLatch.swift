import os

/// A continuation that resolves exactly once, from any thread, and tolerates being
/// resolved BEFORE the continuation is attached.
///
/// The share-map pipeline hand-rolled this shape three times — the style-load belt, the
/// render box, the slot watchdog — because it bridges SDK callbacks that may fire
/// synchronously, where resuming twice is a crash and never resuming is a permanent
/// suspend. Two of those three now use this type; `SnapshotBox` still hand-rolls it
/// because it also owns a non-Sendable `Snapshotter` under the same lock.
///
/// Adding cancellation to that pipeline (ROH-126 blocker 2) made the resolve-before-attach
/// case necessary. `withTaskCancellationHandler` runs `onCancel` immediately, on the
/// cancelling thread, when the task is already cancelled at the moment the handler is
/// installed — which is before the body's `withCheckedContinuation` has produced anything
/// to resume. Dropping that outcome on the floor suspends the caller forever.
///
/// The outcome is therefore kept rather than consumed: `outcome` is written once and never
/// cleared, so it is both the resolved flag and the value, and a waiter that arrives after
/// resolution is handed it instead of parking on a latch that can never fire again. That
/// makes the permanent-suspend state unrepresentable rather than merely unreached — which
/// matters because this is public API offered for reuse, and a reviewer reproduced the
/// wedge against the earlier two-flag version.
public final class ResolveOnceLatch<Value: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value, Never>?
        /// Set by the winning `resolve` and never cleared. Non-nil means resolved.
        var outcome: Value?
    }
    private let lock = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// Call from inside `withCheckedContinuation`. Resumes straight away if the latch has
    /// already resolved.
    ///
    /// Attaching a second continuation while one is still waiting is a caller error — the
    /// first would be dropped and its task would never resume. One latch serves one wait.
    public func attach(_ continuation: CheckedContinuation<Value, Never>) {
        let outcome: Value? = lock.withLock { state in
            if let outcome = state.outcome { return outcome }
            assert(state.continuation == nil, "ResolveOnceLatch serves one wait; the attached continuation would be dropped")
            state.continuation = continuation
            return nil
        }
        // Never resume under the lock.
        if let outcome { continuation.resume(returning: outcome) }
    }

    /// First caller wins; every later call is a no-op.
    public func resolve(_ value: Value) {
        let continuation: CheckedContinuation<Value, Never>? = lock.withLock { state in
            guard state.outcome == nil else { return nil }
            state.outcome = value
            defer { state.continuation = nil }
            return state.continuation      // nil when nobody is waiting yet; attach() delivers
        }
        continuation?.resume(returning: value)
    }
}
