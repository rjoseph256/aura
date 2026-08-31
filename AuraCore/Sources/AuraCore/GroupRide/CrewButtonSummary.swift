import Foundation

/// Everything the compact crew button (ROH-214) and the expanded roster header derive from a
/// `[RosterRow]`. One derivation, shared by the badge, the header text, and VoiceOver — the
/// three can never disagree about the crew, which the review gate caught the first cut doing
/// (badge counted the whole crew while the text counted only the others).
public struct CrewButtonSummary: Equatable, Sendable {
    /// The whole crew, self included — the number on the button's badge.
    public let riderCount: Int
    /// True only when a peer has actually dropped (signal lost) — the one state a rider should
    /// act on. Not `.stopped` (a red light; alarming on it cries wolf all ride) and not
    /// `.awaiting` (every peer starts there, which made a healthy ride begin amber).
    public let needsAttention: Bool
    /// Still a crew of one: nobody has joined yet. The button renders this quietly distinct
    /// from a healthy crew, and the spoken summary says it in words.
    public let isWaitingForCrew: Bool

    private let stopped: Int
    private let dropped: Int
    private let awaiting: Int

    public init(rows: [RosterRow]) {
        riderCount = rows.count
        isWaitingForCrew = rows.count <= 1
        let others = rows.filter { !$0.isSelf }
        stopped = others.filter { $0.status == .stopped }.count
        dropped = others.filter { $0.status == .dropped }.count
        awaiting = others.filter { $0.status == .awaiting }.count
        needsAttention = dropped > 0
    }

    /// "4 riders · 1 stopped · 1 no signal" — the badge's population first, then only the
    /// exception clauses, so the header and the badge always agree. "Crew" for a solo crew
    /// (the expanded empty state carries the waiting words).
    public var displaySummary: String {
        guard !isWaitingForCrew else { return "Crew" }
        return ([headcountClause] + exceptionClauses(awaitingLabel: "waiting"))
            .joined(separator: " · ")
    }

    /// The VoiceOver value: same shape as `displaySummary`, comma-joined (the "·" separator is
    /// read literally by some voices), with `.awaiting` spelled out the way the roster row
    /// speaks it, and the solo case said in words instead of a bare count.
    public var spokenSummary: String {
        guard !isWaitingForCrew else { return "No riders have joined yet" }
        return ([headcountClause] + exceptionClauses(awaitingLabel: "waiting to start"))
            .joined(separator: ", ")
    }

    private var headcountClause: String {
        "\(riderCount) riders"
    }

    private func exceptionClauses(awaitingLabel: String) -> [String] {
        var clauses: [String] = []
        if stopped > 0 { clauses.append("\(stopped) stopped") }
        if dropped > 0 { clauses.append("\(dropped) no signal") }
        if awaiting > 0 { clauses.append("\(awaiting) \(awaitingLabel)") }
        return clauses
    }
}
