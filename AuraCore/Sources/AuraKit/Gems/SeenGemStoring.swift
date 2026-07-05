import Foundation

/// Cross-ride record of which gem ids have actively surfaced (peeked). Seeds the engine's
/// `seenBefore` and is written the moment a gem surfaces, so a mid-ride crash can't un-see it.
@MainActor
public protocol SeenGemStoring {
    func seenGemIDs() -> Set<String>
    func markSeen(_ gemID: String, at date: Date)
}
