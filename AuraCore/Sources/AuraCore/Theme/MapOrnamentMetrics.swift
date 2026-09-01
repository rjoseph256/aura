/// Ornament placement for the Mapbox scale bar (ROH-223). Margins are relative to the
/// MapView's SAFE AREA (SDK contract), the same frame the floating controls pad from —
/// so this is a device-independent composition, not a tuned literal.
public enum MapOrnamentMetrics {
    /// The `.padding(.top, 8)` every top-row floating control uses.
    public static let topControlPadding: Double = 8
    /// Gap between the control's bottom edge and the scale bar.
    public static let controlClearance: Double = 8
    /// Scale-bar top margin that clears a standard top-row control.
    public static let belowTopControlMargin: Double =
        topControlPadding + HUDControlMetrics.standard.size + controlClearance
}
