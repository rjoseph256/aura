import Foundation
import AuraCore

/// Loads the hand-curated gem set bundled with the package. Malformed entries are
/// dropped, never fatal — a stale or partially-bad bundle must not crash a ride.
///
/// NOTE: the current `gems.json` is **placeholder starter content** — a small Pittsburgh
/// seed carrying a `"placeholder": true` flag on every entry (the flag is decode-ignored;
/// it marks these as temporary for humans, not the app). It ships to prove the surface and
/// exercise the tiers; the real dataset — a few hundred researched, well-built-out locations
/// with photos — replaces it before launch. Tracked on the board as ROH-58.
public struct CuratedGemProvider: GemProviding {
    private let bundle: Bundle

    public init(bundle: Bundle? = nil) { self.bundle = bundle ?? .module }

    public func gems(near coordinate: Coordinate) async -> [Gem] {
        guard let url = bundle.url(forResource: "gems", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return Self.decode(data)
    }

    /// Lenient array decode: each element decoded independently, invalid ones dropped.
    public static func decode(_ data: Data) -> [Gem] {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        let decoder = JSONDecoder()
        return raw.compactMap { element in
            guard let elementData = try? JSONSerialization.data(withJSONObject: element) else { return nil }
            return try? decoder.decode(Gem.self, from: elementData)
        }
    }
}
