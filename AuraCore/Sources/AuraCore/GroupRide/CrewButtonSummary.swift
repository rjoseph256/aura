import Foundation

/// Everything the compact crew button (ROH-214) and the expanded roster header derive from a
/// `[RosterRow]`: the badge headcount, whether any crew member deserves a glance, and the
/// display/spoken summaries the old collapsed bar carried. One derivation, shared by the button
/// glyph, the header text, and VoiceOver — no independent source of truth for "who's riding".
public struct CrewButtonSummary: Equatable, Sendable {
    /// The whole crew, self included — the number on the button's badge.
    public let riderCount: Int
    /// True when any non-self peer is not actively riding (stopped, dropped, or still
    /// awaiting) — the button shifts to the warning tint so a changed crew state is
    /// glanceable without expanding the card.
    public let needsAttention: Bool

    private let riding: Int
    private let stopped: Int
    private let dropped: Int

    public init(rows: [RosterRow]) {
        riderCount = rows.count
        let others = rows.filter { !$0.isSelf }
        riding = others.filter { $0.status == .riding }.count
        stopped = others.filter { $0.status == .stopped }.count
        dropped = others.filter { $0.status == .dropped || $0.status == .awaiting }.count
        needsAttention = stopped > 0 || dropped > 0
    }

    /// "3 riding · 1 stopped" — omits zero-count clauses; falls back to a dropped-only
    /// clause if that's the only signal, and to "Crew" for a still-solo crew.
    public var displaySummary: String {
        var clauses: [String] = []
        if riding > 0 { clauses.append("\(riding) riding") }
        if stopped > 0 { clauses.append("\(stopped) stopped") }
        if clauses.isEmpty, dropped > 0 { clauses.append("\(dropped) no signal") }
        return clauses.isEmpty ? "Crew" : clauses.joined(separator: " · ")
    }

    public var spokenSummary: String { displaySummary }
}
