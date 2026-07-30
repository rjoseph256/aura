import Foundation
import AuraCore

/// Copy for a ride the rider never ended. Pure and view-free so the strings are unit-tested
/// rather than eyeballed, and shared by History, the last-ride card, the summary sheet, the
/// share card and the widget so they cannot drift.
///
/// **It describes the recording, not the rider** (spec D4). A rider who rode to the brewery
/// and got a lift home did finish their ride; Aura failed to record the end. The copy must
/// also be true for a ride still being recorded on another device, since a synced second
/// device cannot tell that apart from an abandoned one.
///
/// **And it has to separate two failures.** A ride killed *during* the stop is complete but
/// un-ended. A ride whose rider resumed and was killed later while moving is truncated, and
/// the missing distance is invisible. Both render identically, so the detail line says what
/// was not saved rather than only when recording stopped. This is what `checkpointedAt`, and
/// the schema version it cost, was bought for.
public enum UnfinishedRideCopy {
    public static let label = "No end recorded"

    /// "Recording stops at 2:14 PM. Anything after that wasn't saved." Carries the date too
    /// when the stop was not on `now`'s day. Nil when there is no marker timestamp, which is a
    /// PR #90 dev-build row.
    public static func detail(checkpointedAt: Date?, relativeTo now: Date = Date(),
                              calendar: Calendar = .current) -> String? {
        guard let when = timestamp(checkpointedAt, relativeTo: now, calendar: calendar) else {
            return nil
        }
        return "Recording stops at \(when). Anything after that wasn't saved."
    }

    /// Shown before an irreversible, all-devices delete. It must not claim the ride is intact:
    /// the rider standing in front of this dialog may be missing 40 km.
    public static func deleteWarning(checkpointedAt: Date?, relativeTo now: Date = Date(),
                                     calendar: Calendar = .current) -> String {
        let tail = "Deleting removes it from all your devices."
        guard let when = timestamp(checkpointedAt, relativeTo: now, calendar: calendar) else {
            return "Aura never recorded this ride's end, so anything after the last pause wasn't saved. \(tail)"
        }
        return "Aura recorded this ride up to \(when). Anything after that wasn't saved. \(tail)"
    }

    /// One spoken string. A VoiceOver user handed the same caption as a finished ride has not
    /// been told anything.
    public static func accessibilityLabel(checkpointedAt: Date?, relativeTo now: Date = Date(),
                                          calendar: Calendar = .current) -> String {
        guard let detail = detail(checkpointedAt: checkpointedAt, relativeTo: now,
                                  calendar: calendar) else { return label }
        return "\(label). \(detail)"
    }

    private static func timestamp(_ date: Date?, relativeTo now: Date,
                                  calendar: Calendar) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        // Locale before calendar: DateFormatter's locale setter re-derives the calendar, so
        // assigning it second would discard the caller's explicit one.
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = calendar
        formatter.timeStyle = .short
        formatter.dateStyle = calendar.isDate(date, inSameDayAs: now) ? .none : .medium
        return formatter.string(from: date)
    }
}
