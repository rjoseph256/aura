import Foundation

public struct RosterRow: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let isSelf: Bool
    public let nameResolved: Bool
    public let status: PeerStatus
    public let distanceLabel: String?

    /// Whether the row should carry a "you" marker — visually AND in its spoken label.
    /// It lives here, not in the view, because the view layer has no test target: as an
    /// `if row.isSelf && row.nameResolved` written inline, the visible badge and the
    /// VoiceOver string drifted apart (the badge was gated, the spoken label was not, so an
    /// unresolved self name was announced as "You, you" — the very bug the badge gate
    /// exists to prevent). One property, one rule, and it is testable.
    public var showsSelfMarker: Bool { isSelf && nameResolved }

    public init(id: UUID, name: String, isSelf: Bool, status: PeerStatus, distanceLabel: String?,
                nameResolved: Bool = true) {
        self.id = id
        self.name = name
        self.isSelf = isSelf
        self.status = status
        self.distanceLabel = distanceLabel
        self.nameResolved = nameResolved
    }
}

public enum GroupRosterViewData {
    public static let selfLabel = "You"
    private static let noSignalLabel = "no signal"
    public static func rows(peers: [RidePeer], nameMap: [UUID: String],
                            selfUserID: UUID, selfProgress: Double, isImperial: Bool) -> [RosterRow] {
        var all = peers
        if !all.contains(where: { $0.userID == selfUserID }) {
            all.append(RidePeer(userID: selfUserID, displayName: "",
                                progressMeters: selfProgress, status: .riding))
        }
        let sorted = all.sorted {
            switch ($0.progressMeters, $1.progressMeters) {
            case let (a?, b?): return a != b ? a > b : $0.userID.uuidString < $1.userID.uuidString
            case (nil, _?):    return false
            case (_?, nil):    return true
            case (nil, nil):   return $0.userID.uuidString < $1.userID.uuidString
            }
        }
        return sorted.map { peer in
            let isSelf = peer.userID == selfUserID
            let raw = nameMap[peer.userID] ?? peer.displayName
            let resolved = DisplayName.normalized(raw) != nil
            let name = (isSelf && !resolved) ? Self.selfLabel : DisplayName.forDisplay(raw)
            let distance: String?
            if isSelf {
                distance = nil
            } else if peer.status == .dropped {
                distance = noSignalLabel
            } else {
                distance = PeerDistance.label(selfProgress: selfProgress, peer: peer, isImperial: isImperial)
            }
            return RosterRow(id: peer.userID, name: name, isSelf: isSelf,
                             status: peer.status, distanceLabel: distance,
                             nameResolved: !isSelf || resolved)
        }
    }
}
