import Foundation
import AuraCore

/// The scrub band's pixel arithmetic (spec D6), out of the view so it can be pinned: the
/// fraction↔x mapping the rider's finger depends on, the thumb's y on the silhouette, strip
/// frames with their minimum width, and caption placement with the overlap-drop rule.
public struct ReplayBandGeometry: Equatable, Sendable {
    public let width: Double
    public let thumb: Double
    public let strokeInset: Double
    public static let minStripWidth: Double = 12

    public init(width: Double, thumb: Double, strokeInset: Double) {
        self.width = width; self.thumb = thumb; self.strokeInset = strokeInset
    }

    private var inset: Double { thumb / 2 + strokeInset }
    private var drawable: Double { max(width - 2 * inset, 1) }

    public func x(_ fraction: Double) -> Double { inset + fraction * drawable }

    public func fraction(atX px: Double) -> Double { min(max((px - inset) / drawable, 0), 1) }

    /// y of the silhouette at `fraction` in a band of `height`, using the same mapping
    /// `Sparkline.points` draws with (the silhouette is inset by `thumb / 2` horizontally and
    /// `strokeInset` all round). `samples == nil` is the rail: vertical center.
    public func thumbY(fraction: Double, samples: [Double]?, height: Double) -> Double {
        guard let samples, samples.count > 1 else { return height / 2 }
        let size = CGSize(width: width - thumb, height: height)
        let points = Sparkline.points(values: samples, in: size, inset: strokeInset)
        guard points.count > 1 else { return height / 2 }
        let position = min(max(fraction, 0), 1) * Double(points.count - 1)
        let i = min(Int(position), points.count - 2)
        let t = position - Double(i)
        return points[i].y + (points[i + 1].y - points[i].y) * t
    }

    public struct Frame: Equatable, Sendable { public var x: Double; public var width: Double }

    public func stripFrame(_ hold: ReplayHold) -> Frame {
        let start = x(hold.range.lowerBound)
        let end = max(x(hold.range.upperBound), start + Self.minStripWidth)
        return Frame(x: start, width: end - start)
    }

    public struct Caption: Equatable, Sendable { public var center: Double; public var seconds: TimeInterval }

    /// Captions for holds of at least `minSeconds`, centered under their strips, left to right; a
    /// caption whose `captionWidth` box would overlap the previous one, or overflow the band, is dropped.
    public func captionCenters(holds: [ReplayHold], captionWidth: Double, minSeconds: TimeInterval) -> [Caption] {
        var out: [Caption] = []
        var lastRight = -Double.infinity
        for hold in holds where hold.seconds >= minSeconds {
            let frame = stripFrame(hold)
            let center = frame.x + frame.width / 2
            let left = center - captionWidth / 2, right = center + captionWidth / 2
            guard left >= lastRight, right <= width else { continue }
            out.append(Caption(center: center, seconds: hold.seconds))
            lastRight = right
        }
        return out
    }
}
