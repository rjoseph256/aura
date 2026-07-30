import Foundation

/// Cockpit layout limits kept as plain values so they can be pinned by a test, in the spirit
/// of `HUDControlMetrics`.
public enum HUDLayoutMetrics {
    /// Height, in points, of the cockpit instrument panel in both HUDs.
    ///
    /// A fixed number rather than a share of the screen, because the panel's contents have a
    /// floor they will not shrink below — `minimumScaleFactor` 0.5 on the speed hero and 0.7 on
    /// the instrument values — and a slot under that floor is not a smaller panel, it is the
    /// same panel drawn past both ends of the space the cockpit column reserved for it. Both
    /// HUDs used to ask for `containerRelativeFrame(.vertical, count: 4)`, a quarter of the HUD.
    /// That is 161.75 pt on an iPhone SE and 194.5 pt on an iPhone 17 — below the floor on every
    /// iPhone — so the panel drew at 219 pt regardless and bled past both ends of the quarter it
    /// had reserved: ~29 pt on an SE, over the ROH-101 pause row, and as far again off the
    /// bottom of the screen, which is what cut the CLIMB row off there.
    ///
    /// 219 is that drawn height: the panel keeps exactly the size it has always rendered at, and
    /// the column now reserves the same number. Pinned by a test because lowering it under the
    /// content floor brings the bleed straight back, and because the floor moves with the fonts
    /// in `InstrumentChassis`. Re-derive it by reading the panel's accessibility frame on an
    /// iPhone SE (3rd generation) after any change to those fonts or to the panel's padding.
    public static let instrumentPanelHeight = 219.0

    /// Share of HUD height the group roster may occupy before it is capped.
    ///
    /// ROH-101 inserted a pause row below the control cluster, so on a group navigate ride the
    /// column now stacks a turn card, this roster, a four-entry cluster, the pause row and the
    /// instrument panel. The column does not clip when it overflows: it grows upward and pushes
    /// the cluster, End included, under the turn card. This fraction is the agreed lever if an
    /// iPhone SE overflows, and it is pinned by a test so lowering it is a reviewed decision
    /// rather than something remembered from a device session.
    public static let groupRosterMaxHeightFraction = 0.4

    /// Used until the HUD has been measured once.
    public static let groupRosterFallbackMaxHeight = 320.0
}
