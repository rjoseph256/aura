import Foundation

/// Extracts a join code from pasted text (ROH-229). A shared link — the exact string the
/// lobby's ShareLink writes (`aura://join?code=XXXXXXXX`) — yields its code via the same
/// `DeepLink` grammar production uses; anything else passes through unchanged for the join
/// screen's usual sanitization.
public enum JoinCodePaste {
    public static func extract(_ pasted: String) -> String {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), case let .join(code)? = DeepLink.parse(url) else {
            return pasted
        }
        return code.rawValue
    }
}
