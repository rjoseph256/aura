import AuraCore
import AuraKit
import MapboxMaps
import SwiftUI

/// The navigate HUD's bottom cockpit and the cluster actions that drive it. Split out of
/// `NavigateHUDView.swift` (the pattern `NavigateHUDView+GroupCrew.swift` established) to keep
/// that file under SwiftLint's `file_length` ceiling. Nothing here is group-specific; the
/// crew roster it hosts comes from `+GroupCrew`.
///
/// The members this reaches for are declared without `private` in the main file precisely
/// because of this split — `private` is per-file, so a cross-file extension cannot see them.
extension NavigateHUDView {
    /// The formatted trip strip line, recomputed each render from the latest guidance
    /// update and the current time. nil update (pre-guidance) reads as `.starting`.
    var cruisingState: CruisingState {
        guard let update = guidance.lastUpdate else { return .starting }
        return CruisingPresenter.state(for: update, units: settings.units, now: Date())
    }

    // MARK: Cluster actions

    /// Re-engages puck-following after the rider has panned the map. Snaps under Reduce
    /// Motion, flies otherwise.
    func recenter() {
        if reduceMotion {
            viewport = .followPuck(zoom: 16, bearing: .heading)
        } else {
            withViewportAnimation(.easeOut(duration: 0.4)) {
                viewport = .followPuck(zoom: 16, bearing: .heading)
            }
        }
    }

    /// Toggles voice mute; muting also cuts off any in-flight prompt.
    func toggleMute() {
        isMuted.toggle()
        if isMuted {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
    }

    /// Steps the map zoom for a +/- tap (ROH-57). While following the puck it re-follows at the
    /// new zoom (staying locked on the rider); once the rider has panned off, it zooms around the
    /// current center instead of snapping back — recenter is the separate control for that. Snaps
    /// under Reduce Motion, otherwise a quick 0.3s flick (a smaller camera move than recenter's
    /// re-frame, so a hair snappier on purpose).
    func zoom(_ direction: MapZoomStep.Direction) {
        guard cameraBox.zoom.isFinite else { return }
        let target = MapZoomStep.stepped(from: cameraBox.zoom, direction)
        let next: Viewport
        if viewport.followPuck != nil {
            next = .followPuck(zoom: target, bearing: .heading)
        } else if let center = cameraBox.center {
            next = .camera(center: center, zoom: target, bearing: cameraBox.bearing, pitch: cameraBox.pitch)
        } else {
            // Panned off the puck but no camera frame yet (pre-first-`onCameraChanged`): do
            // nothing rather than snap back to the puck, which zoom must never do.
            return
        }
        if reduceMotion {
            viewport = next
        } else {
            withViewportAnimation(.easeOut(duration: 0.3)) { viewport = next }
        }
    }

    /// The bottom cockpit: a crew-roster + map-controls row floating above the quarter-screen
    /// instrument panel (hero speed + to-go + ETA). The roster (only in a live group ride)
    /// shares that row with the controls as a pill to their left, its bottom edge aligned
    /// with the End (stop) button — bottom alignment keeps the collapsed one-line pill beside
    /// the stop button, and expanding it grows upward. `bottomCockpit` sits in a
    /// `ZStack(alignment: .bottom)` with the turn card as a separate `.overlay(alignment: .top)`
    /// declared after it, so growth here does not clip or push anything off-screen — a full
    /// crew instead grows the column tall enough that the turn card draws over the cluster,
    /// End included, and intercepts its taps. `HUDLayoutMetrics.groupRosterMaxHeightFraction`
    /// caps the roster at ~40% of the HUD to keep that overlap from happening. Solo rides keep
    /// the controls right-aligned via the Spacer fallback. (D9 hides the roster once the host
    /// ends the ride; the solo path never renders it.)
    @ViewBuilder var bottomCockpit: some View {
        VStack(spacing: AuraTheme.Spacing.sm) {
            HStack(alignment: .bottom, spacing: AuraTheme.Spacing.md) {
                if showsGroupChrome, let groupSession {
                    GroupRosterSheet(rows: rosterRows(for: groupSession))
                        .frame(maxHeight: hudHeight > 0
                               ? hudHeight * HUDLayoutMetrics.groupRosterMaxHeightFraction
                               : HUDLayoutMetrics.groupRosterFallbackMaxHeight,
                               alignment: .bottom)
                } else {
                    Spacer(minLength: 0)
                }
                ControlCluster(
                    isFollowing: viewport.followPuck != nil,
                    isMuted: isMuted,
                    onRecenter: { recenter() },
                    // Navigate has no mark-this-spot feature, so omit the button entirely rather
                    // than show it permanently disabled — that also keeps the taller (zoom pill)
                    // cluster clear of the turn card on a short screen (ROH-57).
                    showMarkSpot: false,
                    onToggleMute: { toggleMute() },
                    onZoomIn: { zoom(.zoomIn) },
                    onZoomOut: { zoom(.zoomOut) },
                    onEndRide: { onEndTapped() },
                    isEndDisabled: groupSession?.isEnding == true)
            }
            .padding(.horizontal, AuraTheme.Spacing.lg)

            PauseControl(isPaused: coordinator.isPaused,
                         pausedSeconds: coordinator.currentPauseSeconds,
                         onToggle: { togglePause() })
                .padding(.horizontal, AuraTheme.Spacing.lg)

            InstrumentPanel(
                currentSpeedMetersPerSecond: coordinator.currentSpeedMetersPerSecond,
                units: settings.units,
                trip: cruisingState,
                isPaused: coordinator.isPaused)
                .containerRelativeFrame(.vertical, count: 4, span: 1, spacing: 0)
        }
    }

    /// Pause/resume from the cockpit row. Just the state change: the VoiceOver announcement is
    /// posted inside `PauseControl`'s button action, which is shared by both HUDs, so it is
    /// written once rather than once per HUD.
    func togglePause() {
        if coordinator.isPaused { coordinator.resume() } else { coordinator.pause() }
    }
}
