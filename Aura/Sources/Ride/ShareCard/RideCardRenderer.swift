// Aura/Sources/Ride/ShareCard/RideCardRenderer.swift
import SwiftUI
import AuraKit

/// The shareable image + a preview thumbnail. Sharing a written PNG file URL (not a bare
/// SwiftUI `Image`) is the robust payload for Photos / Messages / Instagram.
struct RideShareImage {
    let fileURL: URL
    let preview: Image
}

/// Renders `ShareCardView` offscreen to a 1080×1350 PNG. `@MainActor` because `ImageRenderer`
/// is main-actor-only; called from `RideSummaryView`'s `.task` (already on the MainActor).
@MainActor
enum RideCardRenderer {
    static func make(_ content: ShareCardContent) -> RideShareImage? {
        let card = ShareCardView(content: content)
            .environment(\.dynamicTypeSize, .large)   // pixel output invariant to Dynamic Type
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3                              // 360×450 pt → 1080×1350 px
        guard let uiImage = renderer.uiImage,
              let data = uiImage.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory.appending(path: "Aura ride.png")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        return RideShareImage(fileURL: url, preview: Image(uiImage: uiImage))
    }
}
