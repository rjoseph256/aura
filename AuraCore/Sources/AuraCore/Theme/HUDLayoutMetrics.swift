import Foundation

/// Cockpit layout limits kept as plain values so they can be pinned by a test, in the spirit
/// of `HUDControlMetrics`.
public enum HUDLayoutMetrics {
    /// Share of HUD height the group roster may occupy before it is capped.
    ///
    /// ROH-101 inserted a pause row below the control cluster, so on a group navigate ride the
    /// column now stacks a turn card, this roster, a four-entry cluster, the pause row and a
    /// panel pinned at a quarter of the screen. The column does not clip when it overflows: it
    /// grows upward and pushes the cluster, End included, under the turn card. This fraction is
    /// the agreed lever if an iPhone SE overflows, and it is pinned by a test so lowering it is
    /// a reviewed decision rather than something remembered from a device session.
    public static let groupRosterMaxHeightFraction = 0.4

    /// Used until the HUD has been measured once.
    public static let groupRosterFallbackMaxHeight = 320.0
}
