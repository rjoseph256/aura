import Observation
import AuraKit
import AuraCore

/// Owns the Home map's session camera and phase. `liveCamera` is written from the live map's
/// high-frequency `onCameraChanged` (MapboxMaps discourages storing that in SwiftUI @State);
/// `idleCamera` is frozen — the snapshot renders it and it updates only when we enter idle or
/// on a reset, so panning never re-renders the snapshot beneath.
@Observable @MainActor final class HomeMapModel {
    var phase: HomeMapPhase = .idle
    var liveCamera: HomeMapCamera
    var idleCamera: HomeMapCamera
    var movedOffRider = false

    init(initial: HomeMapCamera) { liveCamera = initial; idleCamera = initial }

    /// Freeze the idle snapshot at wherever the live map currently is (called on leave/teardown).
    func freezeIdleFromLive() { idleCamera = liveCamera }

    /// Reset both cameras to the rider (cold launch / post-ride).
    func reset(to camera: HomeMapCamera) {
        liveCamera = camera; idleCamera = camera; movedOffRider = false
    }
}
