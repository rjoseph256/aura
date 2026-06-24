import SwiftUI
import AuraCore
import AuraKit

struct RideHUDView: View {
    let makeProvider: () -> LocationStreaming

    @Environment(AppRouter.self) private var router
    @Environment(RideStore.self) private var rideStore
    @Environment(SettingsStore.self) private var settings
    @State private var recorder = RideRecorder(kind: .freeRide)
    @State private var provider: LocationStreaming?
    @State private var streamTask: Task<Void, Never>?
    @State private var finishedRide: Ride?
    @State private var startDate: Date?
    @State private var now = Date()

    private var elapsed: TimeInterval {
        guard let startDate else { return 0 }
        return now.timeIntervalSince(startDate)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RideMapView(track: recorder.track)
            SpeedRail(stats: recorder.stats, elapsed: elapsed, units: settings.units)
                .padding(.trailing, 14).padding(.bottom, 90)
            controls
        }
        // Back-to-home affordance, shown before a ride starts so the screen can be
        // abandoned without having to start and then end a ride.
        .overlay(alignment: .topLeading) {
            if !recorder.isRecording {
                backButton
                    .padding(.top, 56)
                    .padding(.leading, 16)
            }
        }
        .background(AuraTheme.bg)
        // Returning from the summary (or backing out) drops to the plan/tab shell,
        // mirroring NavigateHUDView.
        .sheet(item: $finishedRide, onDismiss: { router.screen = .plan }) {
            RideSummaryView(ride: $0)
        }
        .task(id: recorder.isRecording) {
            guard recorder.isRecording else { return }
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        .onDisappear {
            streamTask?.cancel()
            provider?.stop()
        }
    }

    private var controls: some View {
        Button {
            recorder.isRecording ? endRide() : startRide()
        } label: {
            Text(recorder.isRecording ? "End ride" : "Start free ride")
                .font(.headline).foregroundStyle(.black)
                .padding(.vertical, 14).frame(maxWidth: .infinity)
                .background(recorder.isRecording ? AnyShapeStyle(AuraTheme.pink) : AnyShapeStyle(AuraTheme.auroraGradient),
                            in: Capsule())
        }
        .padding(.horizontal, 24).padding(.bottom, 28)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var backButton: some View {
        Button {
            router.screen = .plan
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel("Back to home")
    }

    private func startRide() {
        let p = makeProvider()
        provider = p
        startDate = Date()
        recorder.start(at: startDate!)
        streamTask = Task { @MainActor in
            for await point in p.points() { recorder.record(point) }
        }
    }

    private func endRide() {
        // Idempotent: only end+save once even if invoked again.
        guard recorder.isRecording else { return }
        streamTask?.cancel()
        provider?.stop()
        let ride = recorder.end(at: Date())
        try? rideStore.save(ride)
        finishedRide = ride
    }
}
