import Foundation
import AuraCore

public protocol GemProviding: Sendable {
    /// Candidate gems relevant near `coordinate`. Curated returns its whole (small) set.
    func gems(near coordinate: Coordinate) async -> [Gem]
}
