import SwiftUI
import UIKit
import UserNotifications

/// Shows whether pause reminders can be delivered, and offers a way back when they cannot.
///
/// The system prompts once per install. A rider who taps Don't Allow at a junction, which is
/// exactly where the first pause tends to happen, would otherwise lose the only mechanism that
/// reaches a pocketed phone, permanently and with nothing telling them so. This row is the way
/// back: it names the state in plain language and, once denied, offers "Open Settings" — the
/// only path left, since iOS never re-prompts after a decline.
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
            }
        }
        .task { await refresh() }
        // Re-read on foreground: the whole point of the row is the rider who taps Open Settings,
        // grants permission and comes back. Without this they return to a row still saying "Off."
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
        .accessibilityElement(children: .combine)
    }

    private func refresh() async {
        status = await UNUserNotificationCenter.current().notificationSettings()
            .authorizationStatus
    }

    private var detail: String {
        switch status {
        case .denied:
            return "Off. Aura can't remind you when a paused ride is still paused."
        case .authorized, .provisional, .ephemeral:
            return "On. Aura reminds you if a paused ride stays paused."
        default:
            return "Aura asks the first time you pause a ride."
        }
    }
}
