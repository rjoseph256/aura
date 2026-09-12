import SwiftUI
import AuraCore
import AuraKit

/// The scrubber (spec D6). Geometry comes from `ReplayBandGeometry`; this file only draws and
/// forwards touches. The silhouette is an `Equatable` child so the per-frame playhead
/// invalidation never re-strokes it. Strips draw ABOVE the silhouette.
struct ReplayScrubBand: View {
    let content: ReplayBandContent
    let timeline: ReplayTimeline
    let playback: ReplayPlayback
    /// Resolved at the playhead's own fraction, so the elevation tag and the spoken value
    /// match the thumb, not the 4 Hz instrument row.
    let readout: ReplayReadout
    let fraction: Double

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption2) private var captionWidth: CGFloat = 44
    @State private var dragMoved = false
    @State private var holdUnderThumb: Int?

    static let thumb: CGFloat = 28
    static let strokeInset: CGFloat = 2
    private static let bandHeight: CGFloat = 88
    private static let captionMinSeconds: TimeInterval = 120

    private var samples: [Double]? {
        if case let .silhouette(s) = content.kind { return s }
        return nil
    }

    var body: some View {
        VStack(spacing: AuraTheme.Spacing.xs) {
            GeometryReader { geo in
                let g = ReplayBandGeometry(width: geo.size.width, thumb: Self.thumb, strokeInset: Self.strokeInset)
                ZStack(alignment: .topLeading) {
                    if let samples {
                        ReplaySilhouette(samples: samples, contrast: contrast)
                            .equatable()
                            .padding(.horizontal, Self.thumb / 2)
                    } else {
                        rail(g, height: geo.size.height)
                    }
                    strips(g, height: geo.size.height)
                    playhead(g, height: geo.size.height)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .contentShape(Rectangle())
                .gesture(drag(g))
            }
            .frame(height: Self.bandHeight)
            captions
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ride scrubber")
        .accessibilityValue(readout.accessibilityValue)
        .accessibilityAdjustableAction(adjust)
        .accessibilityIdentifier(RideTestID.replayBand)
        .sensoryFeedback(.selection, trigger: holdUnderThumb) { _, new in dragMoved && new != nil }
        .onChange(of: fraction) { _, new in
            guard playback.isScrubbing else { return }
            let index = timeline.holds.firstIndex { $0.range.contains(new) }
            if index != holdUnderThumb { holdUnderThumb = index }
        }
        .onDisappear { playback.cancelScrub() }
    }

    // MARK: Layers

    private func strips(_ g: ReplayBandGeometry, height: CGFloat) -> some View {
        ForEach(Array(content.holds.enumerated()), id: \.offset) { _, hold in
            let frame = g.stripFrame(hold)
            Rectangle()
                .fill(AuraTheme.replayHoldStrip)
                .frame(width: frame.width, height: height)
                .offset(x: frame.x)
        }
    }

    private func rail(_ g: ReplayBandGeometry, height: CGFloat) -> some View {
        let start = g.x(0), end = g.x(1), head = g.x(fraction)
        return ZStack(alignment: .leading) {
            Capsule().fill(AuraTheme.textSecondary.opacity(0.25)).frame(width: end - start, height: 6)
            Capsule().fill(AuraTheme.accent).frame(width: max(head - start, 6), height: 6)
        }
        .offset(x: start, y: height / 2 - 3)
    }

    private func playhead(_ g: ReplayBandGeometry, height: CGFloat) -> some View {
        let px = g.x(fraction)
        let py = g.thumbY(fraction: fraction, samples: samples, height: height)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(AuraTheme.accent).frame(width: 2, height: height).offset(x: px - 1)
            Circle()
                .fill(AuraTheme.accent)
                .overlay(Circle().strokeBorder(AuraTheme.background, lineWidth: 2))
                .frame(width: Self.thumb, height: Self.thumb)
                .offset(x: px - Self.thumb / 2, y: py - Self.thumb / 2)
            if samples != nil, let tag = readout.elevationText {
                Text(tag)
                    .font(AuraTheme.Typography.unit)
                    .foregroundStyle(AuraTheme.textPrimary)
                    .padding(.horizontal, AuraTheme.Spacing.sm)
                    .padding(.vertical, AuraTheme.Spacing.xs)
                    .background(AuraTheme.surface, in: Capsule())
                    .offset(x: min(px + Self.thumb / 2 + 4, g.width - 72), y: max(py - 12, 0))
            }
        }
        .accessibilityHidden(true)
        .animation(reduceMotion || playback.isPlaying ? nil : .easeOut(duration: 0.12), value: fraction)
    }

    private var captions: some View {
        GeometryReader { geo in
            let g = ReplayBandGeometry(width: geo.size.width, thumb: Self.thumb, strokeInset: Self.strokeInset)
            let placed = g.captionCenters(holds: content.holds, captionWidth: captionWidth,
                                          minSeconds: Self.captionMinSeconds)
            ForEach(placed, id: \.center) { item in
                Text(RideStatsFormatter(units: .metric).minutes(item.seconds))
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(AuraTheme.secondaryText(contrast))
                    .frame(width: captionWidth)
                    .position(x: item.center, y: geo.size.height / 2)
            }
        }
        .frame(height: max(16, captionWidth * 0.4))
        .accessibilityHidden(true)
    }

    // MARK: Input

    private func drag(_ g: ReplayBandGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !playback.isScrubbing { playback.beginScrub(now: Date()) }
                if abs(value.translation.width) > 4 { dragMoved = true }
                playback.scrub(to: g.fraction(atX: value.location.x))
            }
            .onEnded { value in
                if dragMoved {
                    playback.endScrub(now: Date())
                } else {
                    playback.tap(to: g.fraction(atX: value.location.x), now: Date())
                }
                dragMoved = false
                holdUnderThumb = nil
            }
    }

    /// VoiceOver steps between the timeline's events (spec §5), so every hold is reachable.
    private func adjust(_ direction: AccessibilityAdjustmentDirection) {
        let events = timeline.events
        let target: Double?
        switch direction {
        case .increment: target = events.first { $0 > fraction + 1e-9 }
        case .decrement: target = events.last { $0 < fraction - 1e-9 }
        @unknown default: target = nil
        }
        if let target { playback.tap(to: target, now: Date()) }
    }
}

/// The silhouette alone. `Equatable` on its inputs; the caller applies `.equatable()`.
private struct ReplaySilhouette: View, Equatable {
    let samples: [Double]
    let contrast: ColorSchemeContrast

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.samples == rhs.samples && lhs.contrast == rhs.contrast }

    var body: some View {
        Canvas { context, size in
            let pts = Sparkline.points(values: samples, in: size, inset: ReplayScrubBand.strokeInset)
            guard pts.count > 1 else { return }
            var line = Path()
            line.move(to: pts[0])
            for p in pts.dropFirst() { line.addLine(to: p) }
            var area = line
            area.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: size.height))
            area.addLine(to: CGPoint(x: pts[0].x, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(AuraTheme.accent.opacity(0.18)))
            context.stroke(line, with: .color(AuraTheme.accent),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(AuraTheme.hairline(contrast)).frame(height: 1)
        }
        .accessibilityHidden(true)
    }
}
