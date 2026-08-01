// Aura/Sources/Ride/ShareCard/ShareCardFileStore.swift
import Foundation

/// Where one presentation's share-card PNGs live:
/// `tmp/ShareCard/<rideID>/<presentationUUID>/<generation>/Aura ride.png`.
///
/// The leaf name stays clean — it's user-visible in Messages/Mail/Files — so uniqueness
/// comes from the directories. The per-presentation UUID means a second presentation of
/// the same ride can never overwrite files a still-live consumer of the first
/// presentation's URL may read lazily. Generation 0 = fallback card, 1 = map card.
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
