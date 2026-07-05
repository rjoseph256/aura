import Foundation
import SwiftData

/// SwiftData-backed `SeenGemStoring`. Mirrors `SavedPlacesStore`'s container/context shape.
@MainActor
public final class SeenGemStore: SeenGemStoring {
    private let context: ModelContext
    private var cached: Set<String>

    public init(container: ModelContainer) {
        self.context = ModelContext(container)
        let records = (try? context.fetch(FetchDescriptor<SeenGemRecord>())) ?? []
        self.cached = Set(records.map(\.gemID))
    }

    public func seenGemIDs() -> Set<String> {
        cached
    }

    public func markSeen(_ gemID: String, at date: Date) {
        guard !cached.contains(gemID) else { return }
        cached.insert(gemID)   // optimistic: keep the cache and the context in lockstep
        context.insert(SeenGemRecord(gemID: gemID, firstSeenAt: date))
        do {
            try context.save()
        } catch {
            cached.remove(gemID)   // revert so a retry re-attempts instead of skipping
            assertionFailure("SeenGemStore save failed for \(gemID): \(error)")
        }
    }
}
