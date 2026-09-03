import SwiftUI
import AuraCore

/// The shared crew waiting state (ROH-230) — three variants, one voice, selected by ROLE
/// at the roster (every group rider has a code, so code-presence selects nothing). The
/// lobby variant shows no code (the code card sits directly above it).
struct CrewEmptyState: View {
    enum Variant: Equatable {
        case lobby
        case rosterHost(code: String)
        case rosterGuest
    }
    let variant: Variant

    var body: some View {
        VStack(spacing: AuraTheme.Spacing.xs) {
            Image(systemName: "person.2.wave.2")
                .font(.title2)
                .foregroundStyle(AuraTheme.textSecondary)
            Text("Waiting for your crew…")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AuraTheme.textPrimary)
            switch variant {
            case .lobby:
                EmptyView()
            case let .rosterHost(code):
                JoinCodeText(code: code, size: 22, textStyle: .title3, color: AuraTheme.accent)
                    .padding(.top, AuraTheme.Spacing.xs)
                Text("Share this code so they can join.")
                    .font(.footnote)
                    .foregroundStyle(AuraTheme.textSecondary)
            case .rosterGuest:
                Text("Riders join from the ride they were invited to.")
                    .font(.footnote)
                    .foregroundStyle(AuraTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AuraTheme.Spacing.xl)
    }
}

#Preview("Three variants") {
    VStack {
        CrewEmptyState(variant: .lobby)
        CrewEmptyState(variant: .rosterHost(code: "MX4T7Q2A"))
        CrewEmptyState(variant: .rosterGuest)
    }
    .background(AuraTheme.background)
    .preferredColorScheme(.dark)
}
