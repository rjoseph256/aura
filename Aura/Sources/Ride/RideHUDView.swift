import SwiftUI
import AuraCore
import AuraKit

struct RideHUDView: View {
    @Environment(AppRouter.self) private var router
    @Environment(RideStore.self) private var rideStore
    @Environment(SettingsStore.self) private var settings
    @Environment(LocationService.self) private var location

    @State private var coordinator = RideSessionCoordinator(
        kind: .freeRide, destinationName: nil,
        screen: ScreenWakeController(), activity: RideLiveActivityController.shared)
    @State private var showPermission = false

    var body: some View {
        @Bindable var coordinator = coordinator
        ZStack(alignment: .bottomTrailing) {
            RideMapView(track: coordinator.track)
            SpeedRail(stats: coordinator.stats, elapsed: coordinator.elapsed, units: settings.units)
                .padding(.trailing, AuraTheme.Spacing.lg).padding(.bottom, 90)
            controls
        }
        // Back-to-home affordance, shown before a ride starts so the screen can be
        // abandoned without having to start and then end a ride.
        .overlay(alignment: .topLeading) {
            if !coordinator.isRecording {
                backButton
                    .padding(.top, 8)   // sits in the safe area; no hardcoded status-bar inset
                    .padding(.leading, 16)
            }
        }
        // GPS signal chip — top-trailing so it doesn't collide with the top-leading back button.
        .overlay(alignment: .topTrailing) {
            GPSSignalChip(signal: location.signal)
                .padding(.top, 8).padding(.trailing, 16)
        }
        .background(AuraTheme.background)
        // Returning from the summary (or backing out) drops to the plan/tab shell,
        // mirroring NavigateHUDView.
        .sheet(item: $coordinator.finishedRide, onDismiss: { router.popToRoot() }, content: { ride in
            RideSummaryView(ride: ride, saveFailed: coordinator.saveFailed)
        })
        .sheet(isPresented: $showPermission) {
            LocationPermissionView(onOpenSettings: RideSettingsLink.open)
        }
        .onChange(of: coordinator.isRecording) { _, recording in
            router.isRideActive = recording
        }
        .onDisappear {
            router.isRideActive = false
            coordinator.cancel()
        }
    }

    private var controls: some View {
        Button {
            coordinator.isRecording ? coordinator.finish() : startRide()
        } label: {
            Text(coordinator.isRecording ? "End ride" : "Start free ride")
        }
        // Primary lime when starting; destructive pink only for end-ride.
        .buttonStyle(coordinator.isRecording ? .ctaDestructive : .ctaPrimary)
        .padding(.horizontal, AuraTheme.Spacing.xxl).padding(.bottom, 28)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var backButton: some View {
        Button {
            router.popToRoot()
        } label: {
            Image(systemName: "chevron.left")
        }
        .buttonStyle(.hudControl)
        .accessibilityLabel("Back to home")
    }

    private func startRide() {
        let outcome = coordinator.start(
            location: location, saving: rideStore, units: settings.units,
            authorization: location.authorization)
        if outcome == .permissionDenied { showPermission = true }
    }
}
