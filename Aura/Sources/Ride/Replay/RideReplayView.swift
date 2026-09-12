import SwiftUI
import CoreLocation
import AuraCore
import AuraKit

/// The replay cover (spec D7). Owns the playback state; the map and the controls each run their
/// own `TimelineView`, so the map's body never encloses the row. `context.date` renders; every
/// mutation takes `Date()`.
struct RideReplayView: View {
    let ride: Ride
    let timeline: ReplayTimeline
    let band: ReplayBandContent
    let lines: [[CLLocationCoordinate2D]]

    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var playback: ReplayPlayback
    @State private var lastAnnouncedHold: ReplayPhase?

    init(ride: Ride, timeline: ReplayTimeline, band: ReplayBandContent, lines: [[CLLocationCoordinate2D]]) {
        self.ride = ride
        self.timeline = timeline
        self.band = band
        self.lines = lines
        _playback = State(initialValue: ReplayPlayback(playbackDuration: timeline.playbackDuration))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ReplayMap(timeline: timeline, lines: lines, playback: playback)
                .frame(minHeight: 200, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: AuraTheme.Radius.xl, style: .continuous))
                .padding(.horizontal, AuraTheme.Spacing.lg)
            controls
                .padding(.horizontal, AuraTheme.Spacing.xl)
                .padding(.top, AuraTheme.Spacing.lg)
                .padding(.bottom, AuraTheme.Spacing.xl)
        }
        .background(AuraTheme.background.ignoresSafeArea())
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: AuraTheme.Spacing.md) {
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.hudControl(active: false))
                .accessibilityLabel("Close")
            VStack(alignment: .leading, spacing: AuraTheme.Spacing.xs) {
                Text(ride.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.headline)
                    .foregroundStyle(AuraTheme.textPrimary)
                    .lineLimit(2)
                    // Without this, at accessibility sizes the second line `.lineLimit(2)` should
                    // allow was measured away before layout and the title truncated to one line
                    // with an ellipsis instead of actually wrapping.
                    .fixedSize(horizontal: false, vertical: true)
                Text(ReplayReadout.subtitle(for: ride))
                    .font(.subheadline)
                    .foregroundStyle(AuraTheme.secondaryText(contrast))
                    .lineLimit(1)
                if ride.isUnfinished {
                    UnfinishedRideBadge(checkpointedAt: ride.checkpointedAt, style: .full)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AuraTheme.Spacing.lg)
        .padding(.vertical, AuraTheme.Spacing.md)
    }

    private var controls: some View {
        TimelineView(.animation(paused: !playback.isPlaying)) { context in
            let now = context.date
            let fraction = playback.fraction(at: now)
            // The row re-samples at 4 Hz so numerals do not blur at high rate (spec D5); the
            // band's thumb, tag, and spoken value follow the frame.
            let rowDate = Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate * 4).rounded(.down) / 4)
            let rowSample = timeline.sample(at: playback.fraction(at: rowDate))
            let rowReadout = ReplayReadout(sample: rowSample, timeline: timeline, units: settings.units)
            let bandReadout = ReplayReadout(sample: timeline.sample(at: fraction), timeline: timeline, units: settings.units)
            let ended = playback.isPlaying && playback.hasEnded(at: now)
            VStack(spacing: AuraTheme.Spacing.lg) {
                ReplayInstrumentRow(readout: rowReadout)
                ReplayScrubBand(content: band, timeline: timeline, playback: playback,
                                readout: bandReadout, fraction: fraction)
                playButton
            }
            .onChange(of: ended) { _, isEnded in
                if isEnded { playback.settle() }
            }
            .onChange(of: rowSample.phase) { _, phase in
                // A VoiceOver rider's only channel for a stop reached under play (spec §5). Reset
                // between holds so two identical stops are both announced.
                guard case .hold = phase else { lastAnnouncedHold = nil; return }
                guard playback.isPlaying, phase != lastAnnouncedHold, let text = rowReadout.holdText else { return }
                lastAnnouncedHold = phase
                AccessibilityAnnouncer.announce(text)
            }
        }
    }

    private var playButton: some View {
        Button { playback.togglePlay(now: Date()) } label: {
            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(AuraTheme.background)
                .frame(width: 56, height: 56)
                .background(AuraTheme.accent, in: Circle())
        }
        .accessibilityLabel(playback.isPlaying ? "Pause replay" : "Play replay")
        .accessibilityIdentifier(RideTestID.replayPlay)
    }
}
