import SwiftUI
import AuraCore
import AuraKit

/// The replay rider (spec D8): the riding triangle rotated to the sampled course while moving,
/// the browse disc in a hold and at the end. Fixed 34 pt frame so swapping images (32 pt vs
/// 34 pt canvases) never shifts the annotation. Rotation and pitch are disabled on the replay
/// map, so a geographic bearing is a screen bearing.
struct ReplayMarkerView: View {
    let sample: ReplaySample
    let reduceMotion: Bool

    private var bearing: Double? {
        guard case .moving = sample.phase else { return nil }
        return ReplayMarkerStyle.displayBearing(sample.bearing, reduceMotion: reduceMotion)
    }

    var body: some View {
        Image(uiImage: bearing == nil ? AuraPuck.browseTop : AuraPuck.ridingBearing)
            .rotationEffect(.degrees(bearing ?? 0))
            .frame(width: 34, height: 34)
            .accessibilityHidden(true)
    }
}
