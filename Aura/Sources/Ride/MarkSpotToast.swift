import SwiftUI
import AuraCore

/// A self-dismissing confirmation toast that appears when a spot is marked. Shows a brief message
/// with an "Undo" button. Automatically dismisses after ~4 seconds, respecting Reduce Motion for
/// the transition. Styled with AuraTheme and fully accessible to VoiceOver.
struct MarkSpotToast: View {
    let message: String
    let onUndo: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private let autoDismissDelay: Duration = .seconds(4)

    var body: some View {
        HStack(spacing: 12) {
            Text(message)
                .font(.body.weight(.semibold))
                .foregroundStyle(AuraTheme.textPrimary)

            Spacer(minLength: 0)

            Button(action: onUndo) {
                Text("Undo")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(AuraTheme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Undo"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(AuraTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(AuraTheme.hairline(contrast), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(message))
        .accessibilityHint(Text("Double-tap Undo to remove."))
        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
        .task {
            try? await Task.sleep(for: autoDismissDelay)
            if !Task.isCancelled { onDismiss() }
        }
    }
}
