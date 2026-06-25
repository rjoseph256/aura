import SwiftUI
import UIKit
import AuraCore
import AuraKit

struct RideHUDView: View {
    @Environment(AppRouter.self) private var router
    @Environment(RideStore.self) private var rideStore
    @Environment(SettingsStore.self) private var settings
    @Environment(LocationService.self) private var location
    @State private var recorder = RideRecorder(kind: .freeRide)
    @State private var streamTask: Task<Void, Never>?
    @State private var finishedRide: Ride?
    @State private var saveFailed = false
    @State private var startDate: Date?
    @State private var now = Date()
    @State private var showPermission = false

    private var elapsed: TimeInterval {
        guard let startDate else { return 0 }
        return now.timeIntervalSince(startDate)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RideMapView(track: recorder.track)
            SpeedRail(stats: recorder.stats, elapsed: elapsed, units: settings.units)
                .padding(.trailing, AuraTheme.Spacing.lg).padding(.bottom, 90)
            controls
        }
        // Back-to-home affordance, shown before a ride starts so the screen can be
        // abandoned without having to start and then end a ride.
        .overlay(alignment: .topLeading) {
            if !recorder.isRecording {
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
        .sheet(item: $finishedRide, onDismiss: { router.screen = .plan }, content: {
            RideSummaryView(ride: $0, saveFailed: saveFailed)
        })
        .sheet(isPresented: $showPermission) {
            LocationPermissionView(onOpenSettings: openSettings)
        }
        .task(id: recorder.isRecording) {
            guard recorder.isRecording else { return }
            while !Task.isCancelled {
                now = Date()
                // The controller throttles internally — ticking it here keeps the Live
                // Activity fresh without an extra timer.
                RideLiveActivityController.shared.update(stats: recorder.stats, maneuver: nil)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        .onDisappear {
            streamTask?.cancel()
            location.stop()
            RideScreen.keepAwake(false)
        }
    }

    private var controls: some View {
        Button {
            recorder.isRecording ? endRide() : startRide()
        } label: {
            Text(recorder.isRecording ? "End ride" : "Start free ride")
        }
        // Primary lime when starting; destructive pink only for end-ride.
        .buttonStyle(recorder.isRecording ? .ctaDestructive : .ctaPrimary)
        .padding(.horizontal, AuraTheme.Spacing.xxl).padding(.bottom, 28)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var backButton: some View {
        Button {
            router.screen = .plan
        } label: {
            Image(systemName: "chevron.left")
        }
        .buttonStyle(.hudControl)
        .accessibilityLabel("Back to home")
    }

    private func startRide() {
        switch location.authorization {
        case .denied, .restricted:
            showPermission = true
            return
        default:
            break
        }
        startDate = Date()
        recorder.start(at: startDate!)
        RideScreen.keepAwake(true)
        RideLiveActivityController.shared.start(
            mode: .freeRide, startedAt: startDate!, units: settings.units, destinationName: nil)
        streamTask = Task { @MainActor in
            for await point in location.points() { recorder.record(point) }
        }
    }

    private func endRide() {
        // Idempotent: only end+save once even if invoked again.
        guard recorder.isRecording else { return }
        streamTask?.cancel()
        location.stop()
        RideScreen.keepAwake(false)
        RideLiveActivityController.shared.end()
        let ride = recorder.end(at: Date())
        do { try rideStore.save(ride) } catch { saveFailed = true }
        finishedRide = ride
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
