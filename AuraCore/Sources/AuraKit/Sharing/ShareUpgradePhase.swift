import Foundation

/// Whether a retry from a terminal phase is a real second attempt.
///
/// The distinction exists because `SharePipelineSlot` deliberately stops a *caller* waiting
/// without stopping the *pipeline*, so "no map" arrives in two shapes — see `SlotOutcome`.
///
/// Revision 8 cut the automatic retry, which was the only thing that *branched* on this. Both
/// cases now render the same live offer, and the value survives as the promise the spec makes
/// about what a tap does. Deliberately NOT extended with a "retrying is futile" case for the
/// upgrade re-render failure: `RideCardRenderer.make` fails on `ImageRenderer` returning nil, a
/// PNG encode, or a write — all transient and none a function of the raster — so that path keeps
/// a live offer rather than a designed silence.
public enum Retryability: Equatable, Sendable {
    /// The pipeline ran and produced nothing. There is no negative cache, so a retry re-runs it
    /// in full. This is the offline-at-the-trailhead case ROH-161 exists for.
    ///
    /// "Ran and produced nothing" is slightly loose: a same-key waiter can also read an
    /// owner-cancelled nil here. A retry is still a real second attempt in that case, which is
    /// all this promises.
    case freshAttempt
    /// A ceiling fired, so the pipeline may still be alive. A retry may warm-hit a cache the
    /// pipeline filled after we stopped waiting, or re-join the pipeline still running.
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
    /// `confirming` means an indicator was on screen, so a visible result is owed rather than a
    /// row that empties itself. It is false for a map that landed before any indicator showed.
    case upgraded(confirming: Bool)
}

/// Why an attempt started — which decides only whether the show-delay applies.
///
/// Revision 8 removed `.automatic` with the mechanism that was its only caller. Two cases is
/// still the right shape: `confirming` is now derived from whether an indicator was actually on
/// screen rather than from the origin, so this is read in exactly one place, and a named case at
/// the call site says more than the boolean it could collapse to.
public enum AttemptOrigin: Equatable, Sendable {
    /// The summary's own first attempt. The show-delay applies, so a warm cache hit never
    /// flashes the hint.
    case first
    /// An explicit tap. The rider just pressed a button and needs to see that it registered, so
    /// the indicator shows immediately.
    case riderTap
}

/// What one attempt produced. Deliberately image-free so the presenter stays in AuraKit; the app
/// maps its own outcome onto this and keeps the `UIImage`.
public enum ShareUpgradeResult: Equatable, Sendable {
    case gotMap
    case rejected
    case stoppedWaiting
}
