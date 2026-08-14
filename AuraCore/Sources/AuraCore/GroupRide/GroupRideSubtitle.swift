import Foundation

/// One line under the lobby header saying what sort of ride a rider is about to do (ROH-114 D5.4).
///
/// The lobby is reused byte-for-byte between route rides and destination-free ones, which is an
/// engineering win and a guest-facing defect: without this line the screen looks identical whether
/// the guest is about to be navigated 8 km to a café or turned loose to ride around, and every
/// crew ride that existed before this feature had a destination. The guest has no other signal —
/// they joined by typing a code.
///
/// Pure, and formatted here rather than in the view, so it can be tested. The kind comes from the
/// server's stored column (`GroupRide.Kind`), never re-derived from a nil route.
public enum GroupRideSubtitle {
    /// - Parameters:
    ///   - kind: the ride's stored kind. nil before create/join has landed, which renders nothing
    ///     rather than guessing — the lobby is on screen during that window.
    ///   - placeName: the host's destination by name. Always nil for a guest, who joined by code
    ///     and never had a `Place`, so every line here has to read acceptably without it.
    ///   - distanceMeters: the route's length. nil if the route did not survive to this screen.
    public static func text(kind: GroupRide.Kind?,
                            placeName: String?,
                            distanceMeters: Double?,
                            isImperial: Bool) -> String? {
        switch kind {
        case .none:
            return nil
        case .open:
            // Deliberately not "Open ride" alone. Directly below this line sits an eight-character
            // join code in 40pt numerals, and in that company "open" reads as open to anyone —
            // a claim about who can get in rather than about where the ride goes.
            return "No destination — just riding"
        case .route:
            let distance = distanceMeters.map { formatted($0, isImperial: isImperial) }
            switch (placeName, distance) {
            case let (.some(name), .some(distance)): return "Heading to \(name) · \(distance)"
            case let (.some(name), .none):           return "Heading to \(name)"
            // A guest has no place name, so lead with the fact rather than apologising for the
            // gap: "Heading somewhere" spends a line to say nothing, and collides with the
            // open-ride copy above at a glance.
            case let (.none, .some(distance)):       return "\(distance) route"
            case (.none, .none):                     return "Heading to the host's destination"
            }
        }
    }

    /// Matches the roster's shape (`PeerDistance`) — one decimal, unit suffixed — but converts
    /// through `UnitConverter`, which uses the exact 1609.344. `PeerDistance` carries its own
    /// 1609.34 and takes a `RidePeer`, so it cannot be reused here.
    private static func formatted(_ meters: Double, isImperial: Bool) -> String {
        isImperial
            ? String(format: "%.1f mi", UnitConverter.miles(fromMeters: meters))
            : String(format: "%.1f km", UnitConverter.km(fromMeters: meters))
    }
}
