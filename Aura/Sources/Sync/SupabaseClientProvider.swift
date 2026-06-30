import Foundation
import Supabase

/// Single shared Supabase client for the app. RLS-gated; the anon key is
/// public-safe by design.
enum SupabaseClientProvider {
    static let shared = SupabaseClient(
        supabaseURL: URL(string: "https://wyofhmufnttiqyjkrbxi.supabase.co")!,
        supabaseKey: "sb_publishable_JszmSwhSo_MEC8yue7Z76A_QYwVo84h"
    )
}
