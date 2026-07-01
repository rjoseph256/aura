import Foundation

public struct RosterRow: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let isSelf: Bool
    public let status: PeerStatus
    public let distanceLabel: String?

    public init(id: UUID, name: String, isSelf: Bool, status: PeerStatus, distanceLabel: String?) {
        self.id = id
        self.name = name
        self.isSelf = isSelf
        self.status = status
        self.distanceLabel = distanceLabel
    }
}

public enum GroupRosterViewData {
    private static let selfLabel = "You"
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
            let name = isSelf ? selfLabel
                : DisplayName.forDisplay(nameMap[peer.userID] ?? peer.displayName)
            let distance: String?
            if isSelf { distance = nil }
            else if peer.status == .dropped { distance = noSignalLabel }
            else { distance = PeerDistance.label(selfProgress: selfProgress, peer: peer, isImperial: isImperial) }
            return RosterRow(id: peer.userID, name: name, isSelf: isSelf,
                             status: peer.status, distanceLabel: distance)
        }
    }
}
