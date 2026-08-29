// Aura/Sources/Ride/ShareCard/ShareCardFileStore.swift
import Foundation

/// Where one presentation's share-card PNGs live:
/// `tmp/ShareCard/<rideID>/<presentationUUID>/<generation>/Aura ride.png`.
///
/// The leaf name stays clean — it's user-visible in Messages/Mail/Files — so uniqueness
/// comes from the directories. The per-presentation UUID means a second presentation of
/// the same ride can never overwrite files a still-live consumer of the first
/// presentation's URL may read lazily.
///
/// **Generation 0 is the fallback card; every upgrade attempt that produces one writes the
/// next generation.** Before ROH-161 there was exactly one upgrade, so "1 = map card" was the
/// whole story. A rider may now tap "Add map to card" as often as they like, and each
/// successful attempt needs a URL no live consumer is already reading — the same reason the
/// presentation UUID exists, one level down. The counter lives in the view (`RideSummaryView`),
/// because it is a fact about one presentation's attempts rather than about the layout.
///
/// The accepted cost: files accumulate one per successful attempt under this presentation's
/// UUID directory. Bounded by rider taps on a screen with one exit, in `tmp` (which the system
/// reclaims), each ~200 KB — and `sweepOtherRides()` structurally cannot collect the current
/// ride's subtree, which is exactly what keeps an open share sheet's file readable. So the
/// accumulation outlives the screen and is cleaned up on the next ride, not on Done.
///
/// `nonisolated` is required: under this target's default MainActor isolation the struct
/// would otherwise be `@MainActor`, and the detached sweep closure couldn't touch it.
nonisolated struct ShareCardFileStore: Sendable {
    let rideID: UUID
    private let presentationID = UUID()

    init(rideID: UUID) {
        self.rideID = rideID
    }

    private var root: URL {
        FileManager.default.temporaryDirectory.appending(path: "ShareCard")
    }

    func url(generation: Int) -> URL {
        root.appending(path: rideID.uuidString)
            .appending(path: presentationID.uuidString)
            .appending(path: String(generation))
            .appending(path: "Aura ride.png")
    }

    /// Deletes OTHER rides' `ShareCard/` subtrees older than one hour. The current ride's
    /// subtree is structurally out of reach, which is what keeps an open share sheet's
    /// file alive (the sheet always belongs to the current ride). Detached: pure file I/O
    /// that has no business on the main actor during the summary entrance.
    func sweepOtherRides() {
        let root = self.root
        let keep = rideID.uuidString
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            let cutoff = Date(timeIntervalSinceNow: -3600)
            guard let entries = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { return }
            for entry in entries where entry.lastPathComponent != keep {
                let modified = (try? entry.resourceValues(
                    forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, modified < cutoff {
                    try? fm.removeItem(at: entry)
                }
            }
        }
    }
}
