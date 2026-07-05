import Foundation
import SwiftData

/// SwiftData-backed `SeenGemStoring`. Mirrors `SavedPlacesStore`'s container/context shape.
@MainActor
public final class SeenGemStore: SeenGemStoring {
    private let context: ModelContext

    public init(container: ModelContainer) {
        self.context = ModelContext(container)
    }

    public func seenGemIDs() -> Set<String> {
        let records = (try? context.fetch(FetchDescriptor<SeenGemRecord>())) ?? []
        return Set(records.map(\.gemID))
    }

    public func markSeen(_ gemID: String, at date: Date) {
        guard !seenGemIDs().contains(gemID) else { return }
        context.insert(SeenGemRecord(gemID: gemID, firstSeenAt: date))
        try? context.save()
    }
}
