import Foundation

/// The lobby's crew header + empty-state predicate (ROH-230). The row set always includes
/// self (the seed roster contains the host), so "anyone here yet?" is `count <= 1` — the old
/// `rows.isEmpty` was unreachable and a waiting host read their own name as "Crew · 1 joined".
public enum LobbyCrewLabel {
    public static func isWaiting(totalRows: Int) -> Bool { totalRows <= 1 }
    public static func text(totalRows: Int) -> String {
        isWaiting(totalRows: totalRows) ? "Crew" : "Crew · \(totalRows - 1) joined"
    }
}
