import Foundation

/// Every saved-places invariant, pure: the store persists what these return.
public enum SavedPlacesLogic {
    public static let maxCount = 50

    public enum AddOutcome: Equatable {
        case added([SavedPlace])
        case full
    }

    /// Adds as a favorite. Re-saving an existing spot (same key) replaces it,
    /// adopting the newest name/subtitle while keeping id and kind — and is
    /// exempt from the cap.
    public static func add(_ place: Place, subtitle: String?,
                           to list: [SavedPlace], now: Date) -> AddOutcome {
        let key = SavedPlaceKey(place.coordinate)
        if let index = list.firstIndex(where: {
            $0.id == place.id || SavedPlaceKey($0.coordinate) == key
        }) {
            var updated = list[index]
            updated.name = place.name
            updated.subtitle = subtitle ?? place.subtitle ?? updated.subtitle
            updated.coordinate = place.coordinate
            updated.category = place.category
            updated.savedAt = now
            var next = list
            next[index] = updated
            return .added(next)
        }
        guard list.count < maxCount else { return .full }
        return .added(list + [SavedPlace(place: place, subtitle: subtitle,
                                         kind: .favorite, savedAt: now)])
    }

    public static func remove(id: UUID, from list: [SavedPlace]) -> [SavedPlace] {
        list.filter { $0.id != id }
    }

    /// Trims whitespace; an empty result is a no-op (the UI also guards).
    public static func rename(id: UUID, to name: String,
                              in list: [SavedPlace]) -> [SavedPlace] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return list }
        return list.map { item in
            guard item.id == id else { return item }
            var next = item
            next.name = trimmed
            return next
        }
    }

    /// The previous Home demotes to a favorite with `savedAt` refreshed, so it
    /// surfaces at the top of favorites instead of sinking into date order.
    public static func setHome(id: UUID, in list: [SavedPlace], now: Date) -> [SavedPlace] {
        list.map { item in
            var next = item
            if item.id == id {
                next.kind = .home
            } else if item.kind == .home {
                next.kind = .favorite
                next.savedAt = now
            }
            return next
        }
    }

    public static func removeHome(id: UUID, in list: [SavedPlace]) -> [SavedPlace] {
        list.map { item in
            guard item.id == id, item.kind == .home else { return item }
            var next = item
            next.kind = .favorite
            return next
        }
    }

    /// Flips the resurface flag for one place by id; leaves the rest untouched.
    public static func setResurface(id: UUID, _ on: Bool, in list: [SavedPlace]) -> [SavedPlace] {
        list.map { item in
            guard item.id == id else { return item }
            var next = item
            next.resurface = on
            return next
        }
    }

    /// Read-side pass that absorbs CloudKit merge artifacts: id doubles
    /// (backup-restore), key doubles (two devices saving one spot), and a
    /// two-Home merge. Keeps the newest of each; never writes back — the next
    /// genuine mutation persists the reconciled list. Sorted Home-first, then
    /// savedAt descending.
    public static func reconciled(_ list: [SavedPlace]) -> [SavedPlace] {
        var byID: [UUID: SavedPlace] = [:]
        for item in list where (byID[item.id].map { $0.savedAt <= item.savedAt } ?? true) {
            byID[item.id] = item
        }
        // Preserve resurface across a CloudKit merge: if any same-id copy was flagged, keep it.
        // Snapshot the keys (Array(...)) — mutating byID while iterating its .keys view trips
        // Swift's exclusive-access checks.
        for id in Array(byID.keys) where list.contains(where: { $0.id == id && $0.resurface }) {
            byID[id]?.resurface = true
        }
        var byKey: [SavedPlaceKey: SavedPlace] = [:]
        for item in byID.values {
            let key = SavedPlaceKey(item.coordinate)
            if byKey[key].map({ $0.savedAt <= item.savedAt }) ?? true {
                byKey[key] = item
            }
        }
        var result = Array(byKey.values)
        let homes = result.filter { $0.kind == .home }.sorted { a, b in
            if a.savedAt != b.savedAt { return a.savedAt > b.savedAt }
            return a.id.uuidString < b.id.uuidString   // stable when savedAt ties (CloudKit merge)
        }
        if homes.count > 1 {
            let winner = homes[0].id
            result = result.map { item in
                guard item.kind == .home, item.id != winner else { return item }
                var next = item
                next.kind = .favorite
                return next
            }
        }
        return result.sorted { a, b in
            if (a.kind == .home) != (b.kind == .home) { return a.kind == .home }
            if a.savedAt != b.savedAt { return a.savedAt > b.savedAt }
            return a.id.uuidString < b.id.uuidString   // deterministic order across launches
        }
    }

    public static func saved(matching place: Place,
                             in list: [SavedPlace]) -> SavedPlace? {
        if let byID = list.first(where: { $0.id == place.id }) { return byID }
        let key = SavedPlaceKey(place.coordinate)
        return list.first { SavedPlaceKey($0.coordinate) == key }
    }

    public static func isSaved(_ place: Place, in list: [SavedPlace]) -> Bool {
        saved(matching: place, in: list) != nil
    }
}
