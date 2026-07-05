import SwiftUI
import AuraCore

/// The expanded view for a gem, opened by tapping its pin or peek card. Info-only in Plan 2;
/// Plan 3 adds the "Take me there" CTA below, which kicks off the guided detour (wired in
/// Task 9). `canRoute` disables the CTA while a route can't yet be computed (e.g. no GPS fix).
struct GemDetailSheet: View {
    let gem: Gem
    let distanceText: String
    var canRoute: Bool = true
    var onTakeMeThere: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: GemPinView.symbol(for: gem.category))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AuraTheme.onAccent)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(AuraTheme.accent))
                VStack(alignment: .leading, spacing: 2) {
                    Text(gem.name).font(.title3.weight(.semibold)).foregroundStyle(AuraTheme.textPrimary)
                    Text("\(gem.category.rawValue.capitalized) · \(distanceText)")
                        .font(.subheadline).foregroundStyle(AuraTheme.textSecondary)
                }
            }
            if let asset = gem.photoAsset, UIImage(named: asset) != nil {
                Image(asset).resizable().scaledToFill()
                    .frame(maxWidth: .infinity).frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            if let why = gem.why {
                Text(why).font(.body).foregroundStyle(AuraTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: AuraTheme.Spacing.sm) {
                Button {
                    onTakeMeThere()
                } label: {
                    Label("Take me there", systemImage: "location.north.line.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AuraTheme.Spacing.sm)
                }
                .buttonStyle(.borderedProminent)
                .tint(AuraTheme.accent)
                .foregroundStyle(AuraTheme.onAccent)
                .disabled(!canRoute)
                .accessibilityHint(canRoute
                                    ? "Starts a guided detour to this gem"
                                    : "Waiting for GPS")
                if !canRoute {
                    Text("Waiting for GPS…")
                        .font(.caption)
                        .foregroundStyle(AuraTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
