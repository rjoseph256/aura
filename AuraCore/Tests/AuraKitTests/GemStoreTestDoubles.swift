import Foundation
@testable import AuraKit

/// Shared test doubles for the `GemDiscoveryStore` suites.
@MainActor
final class InMemorySeen: SeenGemStoring {
    var ids: Set<String> = []
    func seenGemIDs() -> Set<String> { ids }
    func markSeen(_ gemID: String, at date: Date) { ids.insert(gemID) }
}

@MainActor
final class SpyHaptics: GemHapticPlaying {
    var count = 0
    func playGemSurfaced() { count += 1 }
}
