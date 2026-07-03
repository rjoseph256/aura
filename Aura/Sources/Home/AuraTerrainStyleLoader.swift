import Foundation
import AuraKit

/// Loads the bundled authored terrain style JSON. Returns nil (→ snapshotter falls back to the
/// dark preset) if the resource is absent or unreadable, so Home never breaks on a bad asset.
enum AuraTerrainStyleLoader {
    static func json(bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: TerrainStyle.authoredStyleResource, withExtension: "json"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.isEmpty else { return nil }
        return text
    }
}
