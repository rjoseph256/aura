import Foundation

/// Assigns each rider a stable palette index. Hash-based so a rider keeps their colour across
/// rides; a deterministic de-collision pass (probe to the next free slot, users in sorted
/// order) makes a single ride's riders distinct when the palette is large enough. UI-free:
/// returns an index the app maps to `AuraTheme.riderPalette`.
public enum PeerPalette {
    public static func assign(userIDs: [UUID], paletteCount: Int) -> [UUID: Int] {
        guard paletteCount > 0 else { return [:] }
        var result: [UUID: Int] = [:]
        var taken = Set<Int>()
        for id in userIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            let base = stableHash(id) % paletteCount
            var idx = base
            if taken.count < paletteCount {                 // room to de-collide
                var probe = 0
                while taken.contains(idx) && probe < paletteCount {
                    probe += 1
                    idx = (base + probe) % paletteCount
                }
            }
            result[id] = idx
            taken.insert(idx)
        }
        return result
    }

    /// Deterministic, platform-stable hash (FNV-1a over the UUID bytes) — `Hashable`'s hash is
    /// per-process-seeded and would not be stable across launches/rides.
    private static func stableHash(_ id: UUID) -> Int {
        var h: UInt64 = 1_469_598_103_934_665_603
        withUnsafeBytes(of: id.uuid) { bytes in
            for b in bytes { h = (h ^ UInt64(b)) &* 1_099_511_628_211 }
        }
        return Int(h & 0x7FFF_FFFF)
    }
}
