import SwiftUI

/// Premium, dark offline-map screen: download the Pittsburgh region for low-signal rides.
struct OfflineMapsView: View {
    @StateObject private var manager = OfflineMapManager()

    var body: some View {
        ZStack {
            AuraTheme.bg.ignoresSafeArea()

            VStack(spacing: 20) {
                Spacer()

                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 52, weight: .regular))
                    .foregroundStyle(AuraTheme.auroraGradient)

                Text("Pittsburgh, offline")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(AuraTheme.text)

                Text("Download the Pittsburgh map for offline rides on low-signal trails.")
                    .font(.system(size: 14))
                    .foregroundColor(AuraTheme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)

                stateArea
                    .frame(minHeight: 52)

                Spacer()

                downloadButton
            }
            .padding(.bottom, 24)
        }
        .navigationTitle("Offline maps")
        .onDisappear { manager.cancel() }
    }

    // MARK: - State area

    @ViewBuilder
    private var stateArea: some View {
        switch manager.phase {
        case .downloading:
            VStack(spacing: 8) {
                ProgressView(value: manager.progress)
                    .tint(AuraTheme.cyan)
                    .frame(maxWidth: 300)
                Text("\(Int(manager.progress * 100))%")
                    .font(.system(size: 13))
                    .foregroundColor(AuraTheme.muted)
            }

        case .finished:
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(AuraTheme.route)

        case .failed(let msg):
            Text("Download failed. \(msg)")
                .font(.system(size: 13))
                .foregroundColor(AuraTheme.pink)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

        case .idle:
            EmptyView()
        }
    }

    // MARK: - CTA

    private var downloadButton: some View {
        Button {
            manager.downloadPittsburgh()
        } label: {
            ZStack {
                AuraTheme.auroraGradient
                Text(manager.phase == .finished ? "Download again" : "Download Pittsburgh")
                    .font(.headline)
                    .foregroundColor(.black)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(manager.phase == .downloading)
        .opacity(manager.phase == .downloading ? 0.6 : 1)
        .padding(.horizontal, 32)
    }
}
