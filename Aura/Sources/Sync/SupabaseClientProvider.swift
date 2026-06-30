import Foundation
import Supabase

/// Single shared Supabase client for the app. URL + anon key are injected at
/// build time (placeholder constants until Task 2 provisions the project).
enum SupabaseClientProvider {
    static let shared = SupabaseClient(
        supabaseURL: URL(string: "https://placeholder.supabase.co")!,
        supabaseKey: "placeholder-anon-key"
    )
}

/// Compile-only proof that a nonisolated async backend method bridges supabase-swift
/// under SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor. Removed/replaced in Task 11.
enum SupabaseSmokeTest {
    nonisolated static func ping() async throws {
        _ = try await SupabaseClientProvider.shared.auth.session
    }
}
