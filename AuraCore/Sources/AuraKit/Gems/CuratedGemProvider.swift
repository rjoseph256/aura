import Foundation
import AuraCore

/// Loads the hand-curated gem set bundled with the package. Malformed entries are
/// dropped, never fatal — a stale or partially-bad bundle must not crash a ride.
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
