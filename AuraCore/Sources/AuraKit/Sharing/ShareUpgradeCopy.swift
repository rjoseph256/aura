import Foundation

/// Every string the share-card upgrade row renders, as plain values so they are unit-tested on the
/// host rather than eyeballed in a preview. The `PauseControlCopy` pattern.
///
/// The caption rule lives here rather than in the view for the same reason the timing rules live
/// in `ShareUpgradePresenter`: the app target has no unit-test bundle, so anything expressed only
/// in `RideSummaryView` is compile-verified and nothing more.
public enum ShareUpgradeCopy {
    public static let upgrading = "Adding your map…"

    /// Names its destination. There is a real route map at the top of the summary
    /// (`StaticRouteMap`) and the share card is never rendered on that screen, so "Add the map"
    /// alone reads as an offer to fix the map the rider is looking at.
    public static let offer = "Add map to card"

    /// Longer than the visible label only where speech needs the article. Revisions 2–4 gave
    /// VoiceOver a disambiguated label and left the visible one ambiguous, having just diagnosed
    /// that ambiguity as a defect for one population.
    public static let offerAccessibilityLabel = "Add the map to your share card"

    public static let confirmation = "Map added"

    /// The connectivity caption.
    ///
    /// §Problem states the rider's real loss as *"I do not know that trying again on wifi would
    /// very likely work"*, and §Copy forbids every failure sentence that might have carried it.
    /// While the automatic retry existed the app closed that gap by *acting* — the rider who did
    /// nothing sometimes got the map anyway. With it cut, telling them is the only channel left.
    ///
    /// A hint, not an apology: no "couldn't", no cause, no diagnosis of the degraded route map
    /// above it.
    public static let connectivityHint = "Works best on Wi-Fi"

    /// The caption under the offer, or `nil` when the row shows none.
    ///
    /// **Withheld until a rider-initiated attempt has failed**, which is the whole design of it.
    /// On first presentation the offer stands alone: the rider has not tried anything yet, and a
    /// hint there pre-empts a tap that usually works. After a failed tap it is the difference
    /// between a rider who learns the recovery path — go home, reopen the ride in History — and
    /// one who taps twice, concludes the feature is broken, and presses Done, which destroys the
    /// screen permanently.
    public static func caption(for phase: ShareUpgradePhase, hasFailedARiderTap: Bool) -> String? {
        guard case .unavailable = phase, hasFailedARiderTap else { return nil }
        return connectivityHint
    }

    /// What VoiceOver announces on entering a terminal phase, or `nil` for a phase that announces
    /// nothing.
    ///
    /// A failed tap must not sound like a successful one — the rider asked, so they are owed the
    /// outcome, and "Map added" against "No map yet" is the distinction. Kept in lockstep with
    /// `caption(for:hasFailedARiderTap:)` so a rider using VoiceOver and a rider reading the row
    /// are told the same thing.
    public static func announcement(for phase: ShareUpgradePhase,
                                    hasFailedARiderTap: Bool) -> String? {
        switch phase {
        case .upgraded:
            return confirmation
        case .unavailable:
            guard let caption = caption(for: phase, hasFailedARiderTap: hasFailedARiderTap) else {
                return "No map yet"
            }
            return "No map yet. \(caption)."
        case .idle, .upgrading, .upgradingVisible:
            return nil
        }
    }
}
