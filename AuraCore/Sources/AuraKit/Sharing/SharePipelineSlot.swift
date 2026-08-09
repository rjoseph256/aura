import Foundation

/// What a caller learned from one trip through the slot.
///
/// The distinction is the point. The slot was rewritten (ROH-126) so a ceiling stops the
/// *caller* waiting without stopping the *pipeline*; `run` used to return nil for both,
/// which told a caller that wanted to offer a retry nothing about whether a retry would be
/// a second attempt or a re-join of a pipeline still running.
public enum SlotOutcome<Value: Sendable>: Sendable {
    /// The pipeline ran to completion. `nil` means it produced nothing.
    ///
    /// A same-key waiter reports whatever the OWNER'S TASK produced, which is not always
    /// what the owner itself was told. If the owner's ceiling fired, `task.cancel()` ran and
    /// that task went on to produce nil, so the waiter reads `.finished(nil)` while the
    /// owner got `.stoppedWaiting`. Both are honest: by the time the waiter is answered that
    /// pipeline is genuinely over, which is the thing a caller weighing a retry needs.
    case finished(Value?)
    /// A ceiling fired. The pipeline may still be alive and holding the slot.
    case stoppedWaiting
}

/// Conditional because it can only be conditional — the compiler cannot synthesize
/// `Equatable` for an arbitrary `Value`, so there was never an unconditional conformance to
/// prefer over this one. Worth saying because the constraint reads like a restriction on
/// callers and is not one: `SlotOutcome<UIImage>` is `Equatable`, since `UIImage` is, via
/// `NSObject`.
extension SlotOutcome: Equatable where Value: Equatable {}

/// The share-map pipeline slot: at most one pipeline alive at a time, single-flight per
/// cache key, with a watchdog ceiling that stops a caller waiting without ever letting a
/// second pipeline start beside a first that is still running.
///
/// **The slot is occupied exactly while a pipeline is alive.** Nothing but the owning
/// pipeline's own unwind clears it. That is the whole design, and it is a change: the
/// watchdog used to clear the slot itself on ceiling, and its identity check —
/// `inFlight?.id == slotID` — confirmed the pipeline it was abandoning was *still alive*,
/// because the pipeline's `defer` is the only other thing that clears the slot. The next
/// request then found an empty slot and started a second pipeline beside the first,
/// defeating both invariants above. Reproduced on same and different keys in the second
/// whole-branch review; reasoning in
/// `docs/superpowers/specs/2026-07-30-roh126-slot-watchdog-cancellation.md`.
///
/// The ceiling's job is to stop making a caller wait on any ONE pipeline. Freeing the slot
/// is a different job and belongs to whoever can establish the pipeline is dead — which
/// only the pipeline can. So the owner's ceiling cancels its pipeline and returns
/// `.stoppedWaiting`, and the slot clears when that pipeline actually unwinds.
///
/// Two limits worth knowing before relying on this:
///
/// - **It does not bound a caller's total wait.** A waiter that sees someone else's key
///   finish loops and arms a fresh ceiling, so N different-key pipelines jumping ahead
///   cost it up to N × `ceiling`. Inherited from the machine this replaces, not introduced
///   here, and unchanged by it.
/// - **Cancellation has to be real, and nothing here can enforce that.** A pipeline that
///   ignores it holds the slot for the life of the owner, and every later caller then pays
///   a full ceiling to be told `.stoppedWaiting`. That is the deliberate trade against the
///   defect above —
///   the old behaviour recovered from this, but only by breaking the invariant — and it is
///   why `onCeiling` exists.
///
/// Lives in AuraKit rather than beside the snapshotter so it is package-testable: it is
/// generic over the result and takes an injectable ceiling timer, so it needs neither
/// MapboxMaps nor UIKit nor twenty seconds of wall clock.
@MainActor
public final class SharePipelineSlot<Value: Sendable> {

    /// `id` is the slot's identity, kept so the release is provably about the right
    /// pipeline even though ownership can no longer change hands under a live one.
    private struct Slot {
        let key: String
        let id: UUID
        let task: Task<Value?, Never>
    }

    /// Outcome of racing a pipeline against the watchdog ceiling.
    private enum Race: Sendable {
        case finished(Value?)
        case ceiling
    }

    private var inFlight: Slot?
    private let ceiling: Duration
    private let ceilingTimer: @Sendable (Duration) async -> Void
    private let onCeiling: (@Sendable (_ key: String, _ isOwner: Bool) -> Void)?

    /// - Parameters:
    ///   - ceiling: how long a caller waits before the watchdog gives up on it.
    ///   - ceilingTimer: injected so the ceiling can be tested without spending it.
    ///     Production leaves it nil and gets a cancellable sleep; tests pass a timer they
    ///     fire by hand. Nil rather than a default closure on purpose — ROH-110: an async
    ///     closure default argument is duplicated into every module that references the
    ///     declaration and the copies can disagree about frame size, which aborts the
    ///     process. Build it here, in the defining module.
    ///   - onCeiling: called whenever a ceiling fires, with the caller's key and whether
    ///     it owned the pipeline. This is the only way the one failure this design cannot
    ///     recover from becomes visible: a pipeline that ignores cancellation holds the
    ///     slot for the life of the process, and without a trace that reads from outside
    ///     as "the share map just stopped working." Repeated ceilings in a log say
    ///     otherwise.
    public init(
        ceiling: Duration = .seconds(20),
        ceilingTimer: (@Sendable (Duration) async -> Void)? = nil,
        onCeiling: (@Sendable (_ key: String, _ isOwner: Bool) -> Void)? = nil
    ) {
        self.ceiling = ceiling
        self.ceilingTimer = ceilingTimer ?? { try? await Task.sleep(for: $0) }
        self.onCeiling = onCeiling
    }

    /// True exactly while a pipeline is alive. The one-pipeline invariant is the point of
    /// this type, so it is observable rather than inferred.
    public var isRunning: Bool { inFlight != nil }

    /// Runs `work` under the slot, joining an in-flight pipeline for the same key instead
    /// of starting a second one.
    ///
    /// The return says which of two things happened, because they are not the same thing to
    /// a caller deciding whether to offer a retry. `.finished(value)` means a pipeline ran
    /// to completion and this is what it produced — nil included, which is a pipeline that
    /// produced nothing rather than one that is still going. `.stoppedWaiting` means a
    /// ceiling fired: this caller is unblocked, but the pipeline may still be alive and
    /// still holding the slot, so a retry is not necessarily a second attempt.
    public func run(key: String, work: @escaping @MainActor () async -> Value?) async -> SlotOutcome<Value> {
        while let current = inFlight {
            switch await race(current.task) {
            case .finished(let value):
                // Same key: the owner's result is ours too. Different key: the owner's
                // `defer` has already cleared the slot, so the loop either exits or finds
                // whoever claimed it in the meantime.
                if current.key == key { return .finished(value) }
            case .ceiling:
                // A waiter's ceiling unblocks THIS caller and nothing else. It must not
                // cancel a pipeline it does not own, and it must not clear the slot,
                // because the pipeline is still alive.
                //
                // This is a real behaviour change and not only an improvement. The old
                // watchdog cleared the slot here, so the `while let` then failed and this
                // waiter went on to run its own pipeline and return a map — which is the
                // second-pipeline defect, but it did serve the caller. Now the caller gets
                // `.stoppedWaiting`. It only reaches this arm after waiting a full ceiling on somebody
                // else's key, so a healthy pipeline still serves it via `.finished`; the
                // regression bites only when the pipeline ahead is pathological, which is
                // the case where a second one alongside it was the wrong answer anyway.
                onCeiling?(key, false)
                return .stoppedWaiting
            }
        }
        // No await between the loop exit and the assignment: claiming the slot has to be
        // one uninterrupted main-actor step or two waiters that woke together both claim.
        let id = UUID()
        let task = Task { [weak self] in
            // Runs before the task completes, so a caller awaiting `task.value` always
            // observes a cleared slot. Cleared on EVERY exit, including rejects — a
            // "clear at the end" would leave a finished task in the slot forever on any
            // failure path and wedge every later request behind it.
            defer { self?.release(id) }
            return await work()
        }
        inFlight = Slot(key: key, id: id, task: task)
        switch await race(task) {
        case .finished(let value):
            return .finished(value)
        case .ceiling:
            // Ask the pipeline to stop, and hand this caller `.stoppedWaiting`. Deliberately does NOT
            // touch the slot: that is the defect this type was rewritten to close.
            task.cancel()
            onCeiling?(key, true)
            return .stoppedWaiting
        }
    }

    /// Races a pipeline against the ceiling.
    ///
    /// Only the ceiling arm is cancellable, and it is cancelled when the pipeline wins so
    /// a resolved race stops sleeping. The other arm cannot be: awaiting a non-throwing
    /// `Task.value` is not a cancellation point, so it necessarily lives until the
    /// pipeline ends, holding nothing but the latch and resolving into a no-op.
    private func race(_ task: Task<Value?, Never>) async -> Race {
        let latch = ResolveOnceLatch<Race>()
        let timer = ceilingTimer
        let ceiling = self.ceiling
        let ceilingArm = Task { await timer(ceiling); latch.resolve(.ceiling) }
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Race, Never>) in
            // The ceiling arm is already running and may have resolved before we got
            // here; the latch parks that outcome and `attach` delivers it.
            latch.attach(continuation)
            Task { latch.resolve(.finished(await task.value)) }
        }
        ceilingArm.cancel()
        return outcome
    }

    /// Called from the owning pipeline's `defer` and from nowhere else. The identity guard
    /// is belt-and-braces now that the watchdog no longer clears the slot — while a
    /// pipeline is alive nothing else can claim it — but it keeps the release correct if
    /// the ownership rules ever loosen again.
    private func release(_ id: UUID) {
        if inFlight?.id == id { inFlight = nil }
    }
}
