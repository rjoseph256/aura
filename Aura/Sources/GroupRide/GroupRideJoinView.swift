import SwiftUI
import UIKit
import AuraCore

/// The Crew screen: **two** ways into a group ride. Start one with no destination (ROH-114), or
/// enter the 8-character code a host shared. Code validation is purely local —
/// `JoinCode(rawValue:)` decides whether it is well-formed, and "Join" only enables once it is.
/// Either action replaces this screen with `.groupRide(…)`; any *server-side* rejection (wrong
/// code / full / ended / rate limited) is a distinct failure surfaced afterward by
/// `GroupRideFlowView`'s `.joinFailed` phase — this view never guesses at that outcome.
///
/// It does not autofocus. A host arriving to *start* a ride used to be met by a keyboard, eight
/// code boxes and a disabled Join, which read as "you are in the wrong place" (D2.1).
///
/// **Known gap, deferred:** once the keyboard is up it still cannot be dismissed. The background
/// tap gesture re-focuses, and there is no scroll view for `scrollDismissesKeyboard`. Inverting
/// that gesture is not the fix — the real `TextField` is `.opacity(0.02)` with no height behind
/// boxes that are `.allowsHitTesting(false)`, so dismissing on background tap would shrink the
/// entry target to a ~22 pt strip and make a near-miss actively unfocus. It needs the scroll
/// view; that is D2.1's third fix and belongs with plan 3's copy pass.
struct GroupRideJoinView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    @State private var rawInput: String
    @FocusState private var isFocused: Bool

    private static let codeLength = 8

    /// `seed` lets previews show a partial/complete code without driving a keyboard. In
    /// production it defaults to an empty start, except the joinFailed Try-again path
    /// (`GroupRideFlowView`), which re-enters this screen seeded with the code the rider
    /// already typed (ROH-231).
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

            startOpenRideButton
                .padding(.top, AuraTheme.Spacing.xl)
                .padding(.horizontal, AuraTheme.Spacing.xxl)

            orDivider
                .padding(.top, AuraTheme.Spacing.lg)
                .padding(.horizontal, AuraTheme.Spacing.xxl)

            codeEntry
                .padding(.top, AuraTheme.Spacing.lg)
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
        // Tap anywhere to focus the code field. NOT inverted to dismiss — see the type's doc
        // comment: the real TextField is a ~22 pt strip, so dismiss-on-background-tap would make
        // a near-miss unfocus rather than focus.
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
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
            Text("Crew")
                .font(.title2.weight(.bold))
                .foregroundStyle(AuraTheme.textPrimary)
            Text("Start a ride together, or enter a code to join one")
                .font(.subheadline)
                .foregroundStyle(AuraTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, AuraTheme.Spacing.xxl)
    }

    // MARK: - Start an open ride

    /// Starts a crew ride with no destination (ROH-114 D2.2).
    ///
    /// `replaceTopWithGroupRide`, never `startGroupRide`: the latter *pushes*, leaving this code
    /// screen underneath, so Back from the lobby would land the host on a code form with a
    /// keyboard; and signed out it stashes the intent without popping, so sign-in resumes on top
    /// of this stale screen. `replaceTopWithGroupRide` exists for exactly this and applies the
    /// same sign-in gate.
    private var startOpenRideButton: some View {
        Button("Start a ride") {
            isFocused = false
            router.replaceTopWithGroupRide(.create(route: nil, place: nil))
        }
        .buttonStyle(.ctaPrimary)
        .accessibilityIdentifier("crew.startOpenRide")
    }

    private var orDivider: some View {
        HStack(spacing: AuraTheme.Spacing.sm) {
            Rectangle().fill(AuraTheme.border).frame(height: 1)
            Text("or join with a code")
                .font(.caption)
                .foregroundStyle(AuraTheme.textSecondary)
                .fixedSize()
            Rectangle().fill(AuraTheme.border).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
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
        // Single path mutation — NOT dismiss() + startGroupRide(). This screen is a pushed
        // destination, so dismiss() and a router push both mutate the same NavigationStack path
        // in one runloop tick and reconcile into a blank, broken push (the manual-join dead-end
        // seen on device). replaceTopWithGroupRide swaps this screen for the group ride in one
        // write and routes through the same auth gate as the deep-link path.
        router.replaceTopWithGroupRide(.join(joinCode))
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
