/// The marker's Reduce Motion rule (spec D10): round the course to the 8-point compass, the
/// peer-pointer precedent. Out of the view so it is pinned.
public enum ReplayMarkerStyle {
    public static func displayBearing(_ raw: Double?, reduceMotion: Bool) -> Double? {
        guard let raw else { return nil }
        guard reduceMotion else { return raw }
        let rounded = ((raw / 45).rounded() * 45).truncatingRemainder(dividingBy: 360)
        return rounded < 0 ? rounded + 360 : rounded
    }
}
