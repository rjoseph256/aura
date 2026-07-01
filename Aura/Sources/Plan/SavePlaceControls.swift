import SwiftUI
import AuraCore

// MARK: - PreviewHeader

/// The route-preview bottom panel's header: destination name/subtitle, the
/// save star, and — while active — the transient Saved/Set-as-Home moment.
struct PreviewHeader: View {
    let destinationName: String
    let isSaved: Bool
    let saveMoment: SaveMoment?
    let onToggleSaved: () -> Void
    let onSetHome: (SavedPlace) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: AuraTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(destinationName)
                        .font(.title3.bold())
                        .foregroundStyle(AuraTheme.textPrimary)
                        .lineLimit(1)
                    Text("Choose a route")
                        .font(.subheadline)
                        .foregroundStyle(AuraTheme.textSecondary)
                }
                Spacer(minLength: 0)
                SaveStarButton(isSaved: isSaved, action: onToggleSaved)
            }
            .padding(.horizontal, AuraTheme.Spacing.xxl)
            .padding(.top, AuraTheme.Spacing.xl)
            .padding(.bottom, AuraTheme.Spacing.lg)

            if let saveMoment {
                SaveMomentBanner(moment: saveMoment, onSetHome: onSetHome)
            }
        }
    }
}

// MARK: - SaveStarButton

/// The route-preview header's save toggle: an explicit 44×44pt hit target
/// (spec D5) that mirrors `isSaved` and reports its own accessibility state.
struct SaveStarButton: View {
    let isSaved: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isSaved ? "star.fill" : "star")
                .font(.title3.weight(.semibold))
                .foregroundStyle(isSaved ? AuraTheme.accent : AuraTheme.textSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Save place")
        .accessibilityValue(isSaved ? "Saved" : "Not saved")
    }
}

// MARK: - SaveMomentBanner

/// Renders the transient row under the route-preview header: the "Saved" +
/// Set-as-Home offer, then its "Home set" confirmation once tapped.
struct SaveMomentBanner: View {
    let moment: SaveMoment
    let onSetHome: (SavedPlace) -> Void

    var body: some View {
        HStack(spacing: AuraTheme.Spacing.md) {
            switch moment {
            case let .saved(saved):
                Text("Saved")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AuraTheme.accent)
                Button("Set as Home") { onSetHome(saved) }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AuraTheme.textPrimary)
            case let .homeSet(demoted):
                Text(demoted ? "Home set · Previous Home kept as a favorite" : "Home set")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AuraTheme.accent)
            }
            Spacer()
        }
        .padding(.horizontal, AuraTheme.Spacing.xxl)
        .padding(.bottom, AuraTheme.Spacing.sm)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }
}
