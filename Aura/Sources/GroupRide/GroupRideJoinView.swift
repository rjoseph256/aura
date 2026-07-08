import SwiftUI
import UIKit
import AuraCore

/// The "Join a ride" screen: an 8-character code entry rendered as individual boxes, a
/// paste affordance, and a single "Join" CTA. Validation is purely local — `JoinCode(rawValue:)`
/// decides whether the code is well-formed, and "Join" only enables once it is. The CTA pushes
/// `.groupRide(.join(code))`; any *server-side* rejection (wrong code / full / ended / rate
/// limited) is a distinct failure surfaced afterward by `GroupRideFlowView`'s `.joinFailed`
/// phase — this view never guesses at that outcome.
struct GroupRideJoinView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    @State private var rawInput: String
    @FocusState private var isFocused: Bool

    private static let codeLength = 8

    /// `seed` lets previews show a partial/complete code without driving a keyboard;
    /// production call sites always use the default empty start.
    init(seed: String = "") {
        _rawInput = State(initialValue: seed)
    }

    /// Uppercased, charset-filtered, length-capped as the rider types — so pasting a
    /// lowercase code or one with stray whitespace still lands in the boxes cleanly.
    private var sanitizedInput: String {
        String(rawInput.uppercased().filter { JoinCode.charset.contains($0) }.prefix(Self.codeLength))
    }

    private var joinCode: JoinCode? { JoinCode(rawValue: sanitizedInput) }
    private var isValid: Bool { joinCode != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, AuraTheme.Spacing.xl)

            codeEntry
                .padding(.top, AuraTheme.Spacing.xxl)
                .padding(.horizontal, AuraTheme.Spacing.xxl)

            pasteButton
                .padding(.top, AuraTheme.Spacing.lg)

            Spacer(minLength: AuraTheme.Spacing.lg)

            joinButton
                .padding(.horizontal, AuraTheme.Spacing.xxl)
                .padding(.bottom, AuraTheme.Spacing.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AuraTheme.background.ignoresSafeArea())
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .task { isFocused = true }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .foregroundStyle(AuraTheme.textSecondary)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: AuraTheme.Spacing.xs) {
            Text("Join a ride")
                .font(.title2.weight(.bold))
                .foregroundStyle(AuraTheme.textPrimary)
            Text("Enter the 8-character code your host shared")
                .font(.subheadline)
                .foregroundStyle(AuraTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, AuraTheme.Spacing.xxl)
    }

    // MARK: - Code entry

    /// A single hidden `TextField` drives focus + input; the visible boxes are purely
    /// derived from `sanitizedInput`, so there's one source of truth for what's been typed.
    private var codeEntry: some View {
        ZStack {
            TextField("", text: $rawInput)
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .focused($isFocused)
                .opacity(0.02) // present for input/focus/paste; invisible to the eye
                .onChange(of: rawInput) { _, _ in rawInput = sanitizedInput }
                .onSubmit(attemptJoin)
                .accessibilityHidden(true)

            HStack(spacing: AuraTheme.Spacing.xs) {
                ForEach(0..<Self.codeLength, id: \.self) { index in
                    codeBox(at: index)
                }
            }
            .allowsHitTesting(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Join code")
        .accessibilityValue(sanitizedInput.isEmpty ? "empty" : spokenCode)
        .accessibilityHint("8 character code")
    }

    private var spokenCode: String {
        sanitizedInput.map(String.init).joined(separator: " ")
    }

    private func codeBox(at index: Int) -> some View {
        let characters = Array(sanitizedInput)
        let character = index < characters.count ? String(characters[index]) : ""
        let isNextToType = index == characters.count && isFocused

        return Text(character)
            .font(AuraTheme.Typography.metricCockpit(20, relativeTo: .title3))
            .foregroundStyle(AuraTheme.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(AuraTheme.surface, in: RoundedRectangle(cornerRadius: AuraTheme.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: AuraTheme.Radius.sm)
                    .strokeBorder(isNextToType ? AuraTheme.accent : AuraTheme.border, lineWidth: isNextToType ? 2 : 1)
            )
    }

    // MARK: - Paste

    private var pasteButton: some View {
        Button {
            if let clipboardString = UIPasteboard.general.string {
                rawInput = clipboardString
            }
        } label: {
            Label("Paste code", systemImage: "doc.on.clipboard")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(AuraTheme.accent)
    }

    // MARK: - Join CTA

    private var joinButton: some View {
        Button("Join") {
            attemptJoin()
        }
        .buttonStyle(.ctaPrimary)
        .disabled(!isValid)
    }

    private func attemptJoin() {
        guard let joinCode else { return }
        isFocused = false
        dismiss()
        router.startGroupRide(.join(joinCode))
    }
}

#Preview("Empty") {
    NavigationStack {
        GroupRideJoinView()
    }
    .environment(AppRouter())
    .preferredColorScheme(.dark)
}

#Preview("Partial entry") {
    NavigationStack {
        GroupRideJoinView(seed: "AB3K9")
    }
    .environment(AppRouter())
    .preferredColorScheme(.dark)
}

#Preview("Valid code") {
    NavigationStack {
        GroupRideJoinView(seed: "AB3KQ9RT")
    }
    .environment(AppRouter())
    .preferredColorScheme(.dark)
}
