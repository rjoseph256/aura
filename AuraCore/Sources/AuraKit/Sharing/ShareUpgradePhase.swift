import Foundation

/// Whether a retry from a terminal phase is a real second attempt.
///
/// The distinction exists because `SharePipelineSlot` deliberately stops a *caller* waiting
/// without stopping the *pipeline*, so "no map" arrives in two shapes that call for different
/// behaviour — see `SlotOutcome`.
public enum Retryability: Equatable, Sendable {
    /// The pipeline ran and produced nothing. There is no negative cache, so a retry re-runs it
    /// in full. This is the offline-at-the-trailhead case ROH-161 exists for, and the only case
    /// the automatic retry is allowed to fire on.
    ///
    /// "Ran and produced nothing" is slightly loose: a same-key waiter can also read an
    /// owner-cancelled nil here. A retry is still a real second attempt in that case, which is
    /// all this promises.
    case freshAttempt
    /// A ceiling fired, so the pipeline may still be alive. A retry may warm-hit a cache the
    /// pipeline filled after we stopped waiting, or re-join the pipeline still running. Worth
    /// offering to a rider who asks — but never done on their behalf.
    case mayRejoin
}

/// What the summary's share-map upgrade row is showing.
///
/// `slow` is deliberately absent. Spec revisions 2–4 had a fourth phase at the deadline whose
/// spinner read "Still adding your map…"; revision 5 deletes it, because the copy contradicted
/// itself (the app said twice that it was adding the map, then offered a button to add the map),
/// "Still" conceded lateness while offering no recourse, and the minimum dwell made it briefly
/// dishonest. The deadline now produces `unavailable(.mayRejoin)` instead.
public enum ShareUpgradePhase: Equatable, Sendable {
    /// No upgrade possible, or none attempted yet. Both meanings, which is why the view gates its
    /// reserved row on `request != nil` rather than on this case.
    case idle
    /// In flight; the indicator is suppressed by the show-delay so a warm cache hit never flashes
    /// it (ROH-126 §Share flow step 4).
    case upgrading
    /// In flight, indicator on screen.
    case upgradingVisible
    /// The card has no map. Reached by the 6 s deadline elapsing with the attempt still
    /// outstanding, or by the attempt resolving without one.
    case unavailable(Retryability)
    /// A map was obtained. Absorbing: no later outcome may retract it.
    ///
    /// `confirming` means the rider asked and waited, so a visible result is owed. It is false
    /// for a map that landed with no tap behind it and for the one-shot automatic retry, which
    /// must say nothing to a rider who has just unlocked their phone.
    case upgraded(confirming: Bool)
}

/// Why an attempt started.
///
/// Revision 5 splits this out of a single `isRetry` flag, which conflated "the rider asked" with
/// "skip the show-delay". That flag would have given the pocketed-phone rider an unprompted
/// spinner and an unprompted "Map added" seconds after unlocking, and it silently dropped the
/// confirmation for a slow *first* attempt — a spinner vanishing with nothing else changing,
/// which is this issue's own symptom delivered in response to nothing.
public enum AttemptOrigin: Equatable, Sendable {
    /// The summary's own first attempt. The show-delay applies.
    case first
    /// An explicit tap: indicator immediately, confirmation on success.
    case riderTap
    /// The one-shot on a real foreground return: indicator immediately (the phase is already
    /// terminal, so a show-delay would be pointless), and no confirmation.
    case automatic
}

/// What one attempt produced. Deliberately image-free so the presenter stays in AuraKit; the app
/// maps its own outcome onto this and keeps the `UIImage`.
public enum ShareUpgradeResult: Equatable, Sendable {
    case gotMap
    case rejected
    case stoppedWaiting
}
