import Foundation

/// Read-time dedup for the ride history. Because `RideRecord.id` is not a unique
/// attribute (CloudKit forbids uniqueness), a backup restore can surface the same
/// logical ride twice. Callers fetch newest-first, so keeping the first occurrence
/// of each id keeps the newest and drops the stale duplicate. Read-only: never blocks a save.
public enum RideHistoryDedup {
    public static func unique<T>(_ items: [T], by id: (T) -> UUID) -> [T] {
        var seen = Set<UUID>()
        var out: [T] = []
        out.reserveCapacity(items.count)
        for item in items where seen.insert(id(item)).inserted {
            out.append(item)
        }
        return out
    }
}
