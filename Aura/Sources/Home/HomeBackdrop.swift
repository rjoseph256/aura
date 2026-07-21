import SwiftUI
import AuraCore
import AuraKit

/// The Home terrain backdrop: a cached, non-interactive rendered image (never a live Map),
/// framed with top/bottom scrims so floating content stays legible. One ignored VoiceOver
/// element under a single labeled wrapper.
///
/// The render `.task` is keyed on the request's `cacheKey`, which includes a quantized size
/// bucket — so a real layout change (rotation, first non-zero layout) re-renders at the right
/// resolution rather than stretching a stale `scaledToFill` image.
struct HomeBackdrop: View {
    let renderer: TerrainSnapshotRendering
    let camera: HomeMapCamera
    var precise: Bool = false
    let placeName: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var settled = false

    var body: some View {
        GeometryReader { geo in
            let req = request(for: geo.size)
            ZStack {
                AuraTheme.background // placeholder while rendering — no flash
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(settled || reduceMotion ? 1.0 : 1.04)
                        .opacity(settled || reduceMotion ? 1.0 : 0.0)
                }
                scrims
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .task(id: req?.cacheKey) {
                guard let req else { return }
                settled = false
                image = await renderer.image(for: req, size: geo.size, scale: displayScale)
                if reduceMotion {
                    settled = true
                } else {
                    withAnimation(.easeOut(duration: 0.6)) { settled = true }
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(placeName.map { "Map of your area, \($0)" } ?? "Map of your area")
    }

    private func request(for size: CGSize) -> TerrainSnapshotRequest? {
        guard size.width > 0, size.height > 0 else { return nil }
        return TerrainSnapshotRequest(
            center: camera.center,
            // The authored-style identity signals the snapshotter to load the bundled JSON, and
            // its version bakes into the cache key so a restyle invalidates stale snapshots.
            styleURI: TerrainStyle.authoredStyleIdentity,
            width: size.width, height: size.height,
            zoom: camera.zoom,
            quantizationDegrees: precise ? TerrainSnapshotRequest.preciseQuantizationDegrees
                                         : TerrainSnapshotRequest.quantizationDegrees)
    }

    // Top + bottom scrims keep the greeting and launch band legible over terrain. They
    // strengthen under Reduce Transparency (opaque-leaning) using the base token.
    private var scrims: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [AuraTheme.background.opacity(reduceTransparency ? 0.95 : 0.7), .clear],
                startPoint: .top, endPoint: .bottom)
                .frame(height: 180)
            Spacer(minLength: 0)
            LinearGradient(
                colors: [.clear, AuraTheme.background.opacity(reduceTransparency ? 0.98 : 0.85)],
                startPoint: .top, endPoint: .bottom)
                .frame(height: 320)
        }
        .ignoresSafeArea()
    }
}
