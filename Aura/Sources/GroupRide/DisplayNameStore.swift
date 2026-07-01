import Foundation
import Observation
import Supabase
import AuraCore

/// Owns the rider's crew-facing display name: the name shown to other riders in a
/// group ride's roster. Seeded from the Apple credential's full name at first
/// sign-in (see `AppleSignInController.Result.fullName`), editable afterward from
/// Settings. `save()` normalizes via `DisplayName`, persists locally, and pushes the
/// change to the backend through the same `upsert_display_name` RPC that
/// `SupabaseGroupRideBackend.signIn(idToken:nonce:displayName:)` calls at sign-in —
/// renaming later doesn't require re-authenticating, so this calls the RPC directly
/// on the shared client rather than replaying `signIn`.
@Observable
@MainActor
public final class DisplayNameStore {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let client: SupabaseClient

    public var name: String

    /// - Parameters:
    ///   - defaults: Where the crew name is mirrored locally (immediate, offline-safe).
    ///   - client: The Supabase client used to push renames to the backend.
    ///   - appleFullName: The full name captured on first Apple sign-in, used only to
    ///     seed the store the first time it's created (before any local value exists).
    public init(defaults: UserDefaults = .standard,
                client: SupabaseClient = SupabaseClientProvider.shared,
                seedingFrom appleFullName: String? = nil) {
        self.defaults = defaults
        self.client = client
        if let stored = defaults.string(forKey: Key.crewDisplayName), !stored.isEmpty {
            name = stored
        } else if let seed = DisplayName.normalized(appleFullName ?? "") {
            name = seed
        } else {
            name = ""
        }
    }

    /// Whether `name` is currently valid to save (non-blank, within the grapheme cap).
    public var isValid: Bool { DisplayName.normalized(name) != nil }

    /// Normalizes and persists `name` locally, then pushes it to the backend so the
    /// rest of the crew sees the update. No-ops (throws) if the current text doesn't
    /// normalize to a valid name — callers should gate the save action on `isValid`.
    public func save() async throws {
        guard let normalized = DisplayName.normalized(name) else {
            throw DisplayNameError.invalid
        }
        name = normalized
        defaults.set(normalized, forKey: Key.crewDisplayName)
        _ = try await client.rpc("upsert_display_name", params: ["p_name": normalized]).execute()
    }

    private enum Key {
        static let crewDisplayName = "crewDisplayName"
    }
}

public enum DisplayNameError: Error, Equatable, Sendable {
    case invalid
}
