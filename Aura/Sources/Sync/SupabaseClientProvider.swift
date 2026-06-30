import Foundation
import Supabase

/// Single shared Supabase client for the app. RLS-gated; the anon key is
/// public-safe by design. `nonisolated` so it can seed a default argument in a
/// nonisolated initializer under SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor.
public enum SupabaseClientProvider {
    public nonisolated static let shared = SupabaseClient(
        supabaseURL: URL(string: "https://wyofhmufnttiqyjkrbxi.supabase.co")!,
        supabaseKey: "sb_publishable_JszmSwhSo_MEC8yue7Z76A_QYwVo84h"
    )
}
