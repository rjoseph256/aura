import SwiftUI
import UIKit
import UserNotifications
import AuraCore

/// Shows whether pause reminders can be delivered, and offers a way back when they cannot.
///
/// Aura asks for notification permission once per install, at ride start
/// (`RideSessionCoordinator.start()`), while the rider is holding the phone and looking at it —
/// not at the first pause. A pause-time ask cannot work: a forgotten pause is backgrounded, and
/// iOS defers the alert until the app is foregrounded again, so the continuation asking for it
/// would never resume. A rider who taps Don't Allow at that ride-start prompt loses the only
/// mechanism that reaches a pocketed phone, permanently and with nothing telling them so. This
/// row is the way back: it names the state in plain language and, once denied, offers "Open
/// Settings" — the only path left, since iOS never re-prompts after a decline.
///
/// Manually mirrors `SettingsView.row`'s icon/title/spacer/control shape (that helper is private
/// to `SettingsView` and this lives in its own file, the same constraint `HealthAccessRow`
/// works under) so it reads as one more row in the Ride section rather than a one-off layout.
struct PauseRemindersRow: View {
    @State private var status: UNAuthorizationStatus = .notDetermined

    var body: some View {
        HStack(spacing: AuraTheme.Spacing.md) {
            Image(systemName: "bell.badge.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AuraTheme.accent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pause reminders")
                    .foregroundStyle(AuraTheme.textPrimary)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(AuraTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if status == .denied {
                Button("Open Settings") { RideSettingsLink.open() }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AuraTheme.accent)
                    // ROH-75's HUDControlMetrics precedent: grow the tap region without growing
                    // the visible weight. This is stationary Settings chrome, not the moving-
                    // rider ride cluster, so the 44 pt `.standard` floor applies, not `.ride`'s
                    // wider 56 pt. A bare footnote-weight Button's hit area is otherwise just its
                    // glyph bounds, well under the minimum.
                    .frame(minWidth: CGFloat(HUDControlMetrics.standard.hitTarget),
                           minHeight: CGFloat(HUDControlMetrics.standard.hitTarget))
                    .contentShape(Rectangle())
            }
        }
        .task { await refresh() }
        // Re-read on foreground: the whole point of the row is the rider who taps Open Settings,
        // grants permission and comes back. Without this they return to a row still saying "Off."
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
        // MarkSpotToast's pattern for a label-plus-button row: combine into one VoiceOver
        // element, restate the label without the button's own text so it isn't spoken twice,
        // and hint the action explicitly only when there is one to take.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Pause reminders. \(detail)"))
        .accessibilityHint(status == .denied
            ? Text("Double-tap Open Settings to allow reminders.")
            : Text(""))
    }

    private func refresh() async {
        status = await UNUserNotificationCenter.current().notificationSettings()
            .authorizationStatus
    }

    private var detail: String {
        switch status {
        case .denied:
            return "Off. Aura can't remind you when a paused ride is still paused."
        // `.provisional` (quiet, no alert/sound) and `.ephemeral` (App Clips) are grouped with
        // `.authorized` rather than given their own copy: this app's own request only ever asks
        // for `[.alert, .sound]` and Aura isn't distributed as an App Clip, so neither is
        // reachable through anything this row's own permission ask does. Handled here anyway so
        // the switch stays exhaustive and correct if that ever changes.
        case .authorized, .provisional, .ephemeral:
            return "On. Aura reminds you if a paused ride stays paused."
        default:
            return "Aura asks when you start a ride."
        }
    }
}
