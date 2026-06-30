import Foundation

/// An 8-character group-ride join code. Uppercase; excludes ambiguous glyphs
/// (O 0 I 1 L). Mirrors the server's `gen_join_code` charset.
public struct JoinCode: Equatable, Codable, Sendable {
    public static let charset = Set("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    public let rawValue: String

    public init?(rawValue: String) {
        let normalized = rawValue.uppercased()
        guard normalized.count == 8, normalized.allSatisfy({ JoinCode.charset.contains($0) })
        else { return nil }
        self.rawValue = normalized
    }
}
