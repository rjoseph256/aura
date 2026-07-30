// Aura/Sources/Ride/ShareCard/RideCardRenderer.swift
import SwiftUI
import AuraKit
import os

/// The shareable image, a preview thumbnail, and the share-sheet title. Sharing a written
/// PNG file URL (not a bare SwiftUI `Image`) is the robust payload for Photos / Messages /
/// Instagram.
struct RideShareImage {
    let fileURL: URL
    let preview: Image
    let title: String
}

/// Renders `ShareCardView` offscreen to a 1080×1350 PNG at `url`. `@MainActor` because
/// `ImageRenderer` is main-actor-only; the PNG encode and file write hop off it.
@MainActor
enum RideCardRenderer {
    /// `nonisolated` so the detached write closure can log; `Logger` is Sendable.
    private nonisolated static let log = Logger(subsystem: "app.aura.ios", category: "ShareCard")

    static func make(_ content: ShareCardContent, mapImage: UIImage?, title: String,
                     writeTo url: URL) async -> RideShareImage? {
        let card = ShareCardView(content: content, mapImage: mapImage)
            .environment(\.dynamicTypeSize, .large)   // pixel output invariant to Dynamic Type
        let renderer = ImageRenderer(content: card)
        renderer.scale = ShareCardLayout.rasterScale    // 360×450 pt → 1080×1350 px
        guard let uiImage = renderer.uiImage else { return nil }
        // Encode + write off the main actor. Creating the directory first is mandatory,
        // not defensive: an atomic write into a missing directory throws, and a failed
        // generation-0 write means Share never enables.
        let wrote = await Task.detached(priority: .userInitiated) {
            guard let data = uiImage.pngData() else { return false }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                return true
            } catch {
                // A failed generation-0 write means Share never enables — worth a trace.
                log.error("Share card write failed at \(url.path, privacy: .public): \(error.localizedDescription)")
                return false
            }
        }.value
        guard wrote else { return nil }
        return RideShareImage(fileURL: url, preview: Image(uiImage: uiImage), title: title)
    }
}
