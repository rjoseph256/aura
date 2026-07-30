import UIKit

/// Posts a VoiceOver announcement. One place, so both HUDs cannot drift, and so the current
/// API lives in exactly one file when it next changes.
enum AccessibilityAnnouncer {
    static func announce(_ message: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        var announcement = AttributedString(message)
        announcement.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(announcement).post()
    }
}
