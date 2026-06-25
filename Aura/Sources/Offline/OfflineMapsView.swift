import SwiftUI

/// Premium, dark offline-map screen: download the Pittsburgh region for low-signal rides.
struct OfflineMapsView: View {
    @StateObject private var manager = OfflineMapManager()
    @ScaledMetric(relativeTo: .largeTitle) private var glyphSize: CGFloat = 52

    var body: some View {
        ZStack {
            AuraTheme.background.ignoresSafeArea()

            VStack(spacing: AuraTheme.Spacing.xl) {
                Spacer()

                Image(systemName: "arrow.down.circle")
                    .font(.system(size: glyphSize, weight: .regular))
                    .foregroundStyle(AuraTheme.accent)

                Text("Pittsburgh, offline")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(AuraTheme.textPrimary)

                Text("Download the Pittsburgh map for offline rides on low-signal trails.")
                    .font(.subheadline)
                    .foregroundStyle(AuraTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)

                stateArea
                    .frame(minHeight: 52)

                Spacer()

                downloadButton
            }
            .padding(.bottom, AuraTheme.Spacing.xxl)
        }
        .navigationTitle("Offline maps")
        .onDisappear { manager.cancel() }
    }

    // MARK: - State area

    @ViewBuilder
    private var stateArea: some View {
        switch manager.phase {
        case .downloading:
            VStack(spacing: AuraTheme.Spacing.sm) {
                ProgressView(value: manager.progress)
                    .tint(AuraTheme.accent)
                    .frame(maxWidth: 300)
                Text("\(Int(manager.progress * 100))%")
                    .font(.footnote)
                    .foregroundStyle(AuraTheme.textSecondary)
            }

        case .finished:
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AuraTheme.accent)

        case .failed(let msg):
            Text("Download failed. \(msg)")
                .font(.footnote)
                .foregroundStyle(AuraTheme.destructive)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

        case .idle:
            EmptyView()
        }
    }

    // MARK: - CTA

    private var downloadButton: some View {
        Button(manager.phase == .finished ? "Download again" : "Download Pittsburgh") {
            manager.downloadPittsburgh()
        }
        .buttonStyle(.ctaPrimary)
        .disabled(manager.phase == .downloading)
        .padding(.horizontal, AuraTheme.Spacing.xxl)
    }
}
