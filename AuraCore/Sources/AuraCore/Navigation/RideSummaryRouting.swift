/// The navigation path that presents a finished-ride summary (ROH-85).
///
/// It COLLAPSES the whole stack to a single `.rideSummary` entry, deliberately NOT preserving
/// the HUD or any screen beneath it (e.g. the `.preview` that sits under a navigate ride). Only
/// Home remains beneath, so `popToRoot()` on Done is a single-level pop straight to Home with
/// nothing stale to flash. Every ride end already returns to Home, so discarding prior entries
/// matches existing behavior. Pure so the "single entry" invariant is unit-tested.
public enum RideSummaryRouting {
    public static func collapsed(ride: Ride, saveFailed: Bool) -> [AppRoute] {
        [.rideSummary(RideSummaryPayload(ride: ride, saveFailed: saveFailed))]
    }
}
