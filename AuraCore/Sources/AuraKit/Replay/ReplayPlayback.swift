import Foundation
import Observation

/// Playback state for the replay screen (spec D11). The fraction is DERIVED from an anchor,
/// never accumulated: a view reads `fraction(at:)` with its clock's date and writes nothing.
/// Every write is an event, and every event takes the caller's LIVE `Date()`. A paused
/// `TimelineView` hands out a frozen date; anchoring on it starts playback from wherever
/// the rider hesitated to (plan review, v1).
///
/// In AuraKit rather than the app target for the reason `ShareUpgradePresenter` is: the app
/// target has no test bundle.
@MainActor @Observable
public final class ReplayPlayback {
    private let playbackDuration: TimeInterval
    public private(set) var anchorFraction: Double = 0
    public private(set) var isPlaying = false
    public private(set) var isScrubbing = false
    @ObservationIgnored private var anchorDate = Date.distantPast
    @ObservationIgnored private var resumeAfterScrub = false

    public init(playbackDuration: TimeInterval) {
        self.playbackDuration = max(playbackDuration, 0.001)
    }

    public func fraction(at now: Date) -> Double {
        guard isPlaying else { return anchorFraction }
        return Self.clamp(anchorFraction + now.timeIntervalSince(anchorDate) / playbackDuration)
    }

    public func hasEnded(at now: Date) -> Bool { fraction(at: now) >= 1 }

    /// D4: play at the end restarts from 0.
    /// A scrub owns playback until it ends (spec D4); Play mid-drag is a no-op.
    public func play(now: Date) {
        guard !isScrubbing else { return }
        if anchorFraction >= 1 { anchorFraction = 0 }
        anchorDate = now
        isPlaying = true
    }

    public func pause(now: Date) {
        anchorFraction = fraction(at: now)
        isPlaying = false
    }

    public func togglePlay(now: Date) {
        if isPlaying { pause(now: now) } else { play(now: now) }
    }

    /// Idempotent: a second touch-down during a scrub keeps the first one's resume intent.
    public func beginScrub(now: Date) {
        guard !isScrubbing else { return }
        resumeAfterScrub = isPlaying
        pause(now: now)
        isScrubbing = true
    }

    public func scrub(to fraction: Double) {
        anchorFraction = Self.clamp(fraction)
    }

    /// D4: resumes iff it was playing when the scrub began and the rider did not scrub to the end.
    public func endScrub(now: Date) {
        isScrubbing = false
        if resumeAfterScrub, anchorFraction < 1 { play(now: now) }
        resumeAfterScrub = false
    }

    /// A tap on the band (a drag that never moved): land there, paused, whatever was happening.
    public func tap(to fraction: Double, now: Date) {
        isScrubbing = false
        resumeAfterScrub = false
        anchorFraction = Self.clamp(fraction)
        isPlaying = false
    }

    /// A drag that never delivered `onEnded` (system gesture, dismissal): drop the latch.
    public func cancelScrub() {
        isScrubbing = false
        resumeAfterScrub = false
    }

    /// Called by the view when it observes `hasEnded`: park at 1, not playing.
    public func settle() {
        anchorFraction = 1
        isPlaying = false
    }

    private static func clamp(_ f: Double) -> Double { min(max(f.isFinite ? f : 0, 0), 1) }
}
