import Foundation

/// The single derivation of rider identity for every surface (ROH-228): resolved display
/// names, latched hue indices, and collision-widened monograms — all over peers-minus-self.
/// The lobby and the map LOOK THIS UP; neither may call `RiderMonogram.assign` or
/// `PeerPalette.assign` itself (a shared function with different input sets is the disease
/// this bundle cures, spec §1.2 — first for hue, and at the plan gate for labels too).
public struct CrewIdentity: Equatable, Sendable {
    public var names: [UUID: String]
    public var colors: [UUID: Int]
    public var monograms: [UUID: String]

    public static let empty = CrewIdentity(names: [:], colors: [:], monograms: [:])

    public init(names: [UUID: String], colors: [UUID: Int], monograms: [UUID: String]) {
        self.names = names
        self.colors = colors
        self.monograms = monograms
    }

    public static func derive(peers: [RidePeer], selfUserID: UUID?,
                              nameMap: [UUID: String], colors: [UUID: Int]) -> CrewIdentity {
        let others = peers.filter { $0.userID != selfUserID }
        let names = Dictionary(uniqueKeysWithValues: others.map {
            ($0.userID, DisplayName.forDisplay(nameMap[$0.userID] ?? $0.displayName))
        })
        return CrewIdentity(names: names, colors: colors, monograms: RiderMonogram.assign(names: names))
    }
}
