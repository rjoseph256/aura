import Foundation

/// Display-name validation, shared by the create/join gate and the settings editor. Grapheme-aware
/// 40-cap matches the server's `left(p_name, 40)` so what you type equals what the crew sees.
public enum DisplayName {
    public static let maxGraphemes = 40
    public static func normalized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxGraphemes))   // String.prefix is grapheme-cluster based
    }
    public static func forDisplay(_ raw: String) -> String { normalized(raw) ?? "Rider" }
}
