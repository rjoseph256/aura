import Foundation

/// A short, colour-independent per-rider label for the map dot. Normally the first letter
/// (today's behaviour); riders sharing a label are widened — one width step at a time, all
/// colliders together — until the labels are mutually distinct, so two close riders whose names
/// start with the same letter are still tell-apart-able (and it works for colour-blind riders).
/// A final index fallback guarantees distinctness even for identical names.
public enum RiderMonogram {
    public static func assign(names: [UUID: String]) -> [UUID: String] {
        var widths = names.mapValues { _ in 1 }
        for _ in 0..<6 {
            let labels = labelsFor(names, widths: widths)
            let stuck = collisions(labels)
            if stuck.isEmpty { return labels }
            for ids in stuck { for id in ids { widths[id, default: 1] += 1 } }
        }
        // Cap reached (e.g. identical names): break remaining ties by sorted-uuid index.
        var labels = labelsFor(names, widths: widths)
        for ids in collisions(labels) {
            for (i, id) in ids.sorted(by: { $0.uuidString < $1.uuidString }).enumerated() {
                labels[id] = "\(labels[id] ?? "")\(i + 1)"
            }
        }
        return labels
    }

    private static func labelsFor(_ names: [UUID: String], widths: [UUID: Int]) -> [UUID: String] {
        names.reduce(into: [UUID: String]()) { $0[$1.key] = label($1.value, width: widths[$1.key] ?? 1) }
    }

    /// Groups of userIDs that share a label (each group has >1 member).
    private static func collisions(_ labels: [UUID: String]) -> [[UUID]] {
        var byLabel: [String: [UUID]] = [:]
        for (id, l) in labels { byLabel[l, default: []].append(id) }
        return byLabel.values.filter { $0.count > 1 }.map { $0 }
    }

    /// width 1 → first letter; width 2 → first+last-word initials for a multi-word name, else the
    /// first two letters; width ≥3 → the first `width` letters of the name (spaces removed).
    private static func label(_ name: String, width: Int) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if width <= 1 { return String(trimmed.prefix(1)).uppercased() }
        let words = trimmed.split(separator: " ")
        if width == 2, words.count >= 2, let f = words.first?.first, let l = words.last?.first {
            return "\(f)\(l)".uppercased()
        }
        return String(trimmed.replacingOccurrences(of: " ", with: "").prefix(width)).uppercased()
    }
}
