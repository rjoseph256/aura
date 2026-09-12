import Foundation
import AuraCore

/// Every string the replay's instrument row, hold capsule, elevation tag, and VoiceOver
/// surfaces show, resolved from one sample (spec D5, D7). The views concatenate nothing.
public struct ReplayReadout: Equatable, Sendable {
    public let speedText: String
    public let speedUnit: String
    public let distanceText: String
    public let distanceUnit: String
    public let timeText: String
    public let elevationText: String?
    public let holdText: String?
    public let accessibilityValue: String
    public let accessibilityLabel: String

    public init(sample: ReplaySample, timeline: ReplayTimeline, units: DistanceUnits) {
        let fmt = RideStatsFormatter(units: units)
        speedText = sample.speedMetersPerSecond.map { fmt.speedValue($0) } ?? "—"
        speedUnit = fmt.speedUnit
        let soFar = fmt.distanceValue(sample.distanceMeters)
        let total = fmt.distanceValue(timeline.totalDistanceMeters)
        distanceText = "\(soFar) / \(total)"
        distanceUnit = fmt.distanceUnit
        let elapsed = PauseControlCopy.clock(sample.seconds)
        let totalTime = PauseControlCopy.clock(timeline.totalSeconds)
        timeText = "\(elapsed) / \(totalTime)"
        elevationText = sample.elevation.map { "\(fmt.elevationValue($0)) \(fmt.elevationUnit)" }
        if case let .hold(kind, seconds) = sample.phase {
            holdText = Self.holdLabel(kind: kind, seconds: seconds)
        } else {
            holdText = nil
        }
        let minutes = Int(sample.seconds / 60)
        accessibilityValue = "\(soFar) \(fmt.distanceUnitSpoken), \(minutes) minute\(minutes == 1 ? "" : "s")"
        var parts: [String] = []
        if let holdText { parts.append("\(holdText).") }
        if let speed = sample.speedMetersPerSecond {
            parts.append("Speed \(fmt.speedValue(speed)) \(fmt.speedUnitSpoken).")
        } else {
            parts.append("Speed unavailable.")
        }
        parts.append("Distance \(soFar) of \(total) \(fmt.distanceUnitSpoken).")
        parts.append("Time \(elapsed) of \(totalTime).")
        accessibilityLabel = parts.joined(separator: " ")
    }

    /// "Stopped · 10 min", "Paused · 45 s", "No signal · 3 min". Minutes at or above 60 s
    /// (`RideStatsFormatter.minutes`, which truncates), seconds below.
    public static func holdLabel(kind: ReplayHold.Kind, seconds: TimeInterval) -> String {
        let word: String
        switch kind {
        case .stopped: word = "Stopped"
        case .paused: word = "Paused"
        case .signalLost: word = "No signal"
        }
        let duration = seconds >= 60 ? RideStatsFormatter(units: .metric).minutes(seconds) : "\(Int(seconds)) s"
        return "\(word) · \(duration)"
    }

    /// The History row's three-valued rule; `HistoryView` keeps its own private copy.
    public static func subtitle(for ride: Ride) -> String {
        if let name = ride.destinationName, !name.isEmpty { return name }
        return ride.kind == .navigate ? "Navigated" : "Explore"
    }
}
