import Foundation
import AuraCore

/// Read seam over the saved-places store for the gem layer: the resurface-flagged
/// places that behave as Tier-3 personal gems. `@MainActor` because the store is.
public protocol ResurfacePlacesReading: Sendable {
    @MainActor func resurfacePlaces() -> [SavedPlace]
}
