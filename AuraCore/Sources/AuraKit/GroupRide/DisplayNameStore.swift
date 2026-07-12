import Foundation
import Observation
import AuraCore

/// Owns the rider's crew-facing display name: the name shown to other riders in a
/// group ride's roster. Seeded from the Apple credential's full name at first
/// sign-in (see `AppleCredential.fullName`), editable afterward from
/// Settings. `save()` normalizes via `DisplayName`, persists locally, and pushes the
/// change through the `GroupRideBackend` seam's `renameDisplayName` — the same
/// `upsert_display_name` RPC that `SupabaseGroupRideBackend.signIn(idToken:nonce:displayName:)`
/// calls at sign-in — renaming later doesn't require re-authenticating, so this calls
/// the backend directly rather than replaying `signIn`.
@Observable
@MainActor
public final class DisplayNameStore {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let backend: any GroupRideBackend

    public var name: String

    /// - Parameters:
    ///   - defaults: Where the crew name is mirrored locally (immediate, offline-safe).
    ///   - backend: The Group Rides backend seam used to push renames.
    ///   - appleFullName: The full name captured on first Apple sign-in, used only to
    ///     seed the store the first time it's created (before any local value exists).
    public init(defaults: UserDefaults = .standard,
                backend: any GroupRideBackend,
                seedingFrom appleFullName: String? = nil) {
        self.defaults = defaults
        self.backend = backend
        if let stored = defaults.string(forKey: DisplayNameStore.crewDisplayNameKey), !stored.isEmpty {
            name = stored
        } else if let seed = DisplayName.normalized(appleFullName ?? "") {
            name = seed
        } else {
            name = ""
        }
    }

    /// Whether `name` is currently valid to save (non-blank, within the grapheme cap).
    public var isValid: Bool { DisplayName.normalized(name) != nil }

    /// Normalizes `name`, pushes it to the backend first, and mirrors it locally only on
    /// success — so a failed backend save can't leave a phantom local name. No-ops (throws)
    /// if the current text doesn't normalize to a valid name — callers should gate the save
    /// action on `isValid`.
    public func save() async throws {
        try await save(name)
    }

    /// Saves a candidate string without first assigning it to `name`, so `name` (the
    /// committed value the Settings row previews) changes only on a successful backend
    /// push. The editor edits a transient draft and calls this — backing out without
    /// saving therefore never dirties the previewed name. Throws on an invalid candidate
    /// or a backend failure, leaving `name` untouched in both cases.
    public func save(_ candidate: String) async throws {
        guard let normalized = DisplayName.normalized(candidate) else {
            throw DisplayNameError.invalid
        }
        try await backend.renameDisplayName(normalized)
        name = normalized
        defaults.set(normalized, forKey: DisplayNameStore.crewDisplayNameKey)
    }

    /// The `UserDefaults` key under which the crew display name is mirrored locally.
    /// Shared with `GroupRideFlowView.makeSession()`, which reads the same key to seed
    /// the live session's `displayNameProvider` — kept as a single source of truth so
    /// the string literal exists exactly once. `nonisolated` so it can be read from the
    /// non-isolated `displayNameProvider` closure without hopping to the main actor.
    public nonisolated static let crewDisplayNameKey = "crewDisplayName"
}

public enum DisplayNameError: Error, Equatable, Sendable {
    case invalid
}
