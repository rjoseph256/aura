import Foundation

/// Pins saved places above Mapbox suggestions while the rider types.
public enum SavedPlaceMatcher {
    public static func matches(query: String, in list: [SavedPlace],
                               limit: Int = 3) -> [SavedPlace] {
        let folded = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !folded.isEmpty else { return [] }
        let hits = list.filter { item in
            if item.kind == .home, "home".hasPrefix(folded) { return true }
            let name = item.name.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                         locale: nil)
            if name.contains(folded) { return true }
            guard let subtitle = item.subtitle else { return false }
            return subtitle.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                    locale: nil).contains(folded)
        }
        let ordered = hits.sorted { a, b in
            if (a.kind == .home) != (b.kind == .home) { return a.kind == .home }
            return a.savedAt > b.savedAt
        }
        return Array(ordered.prefix(limit))
    }
}
