import Foundation

public enum GPXParser {
    public enum ParseError: Error { case invalidXML }

    public static func parse(_ xml: String) throws -> GPXTrack {
        guard let data = xml.data(using: .utf8) else { throw ParseError.invalidXML }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw ParseError.invalidXML }
        return GPXTrack(segments: delegate.segments.map { RideSegment(points: $0) })
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        /// Completed segments, plus the one currently open. A `<trkseg>` opens a segment;
        /// a `<trkpt>` outside one opens a defensive segment rather than being dropped.
        var segments: [[TrackPoint]] = []
        private var current: [TrackPoint]?
        private var lat: Double?
        private var lon: Double?
        private var ele: Double?
        private var time: Date?
        private var buffer = ""
        // Instance-level (one per parse) rather than a shared static: a shared
        // static ISO8601DateFormatter is a non-Sendable global that Swift 6
        // strict concurrency rejects. The Delegate is created fresh per parse,
        // so this is functionally identical.
        private let iso: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
        }()

        func parser(_ p: XMLParser, didStartElement el: String, namespaceURI: String?,
                    qualifiedName: String?, attributes attrs: [String: String]) {
            buffer = ""
            if el == "trkseg" {
                closeCurrentSegment()
                current = []
            }
            if el == "trkpt" {
                if current == nil { current = [] }   // malformed: trkpt outside a trkseg
                // nil when the attribute is missing or non-numeric; an explicit
                // "0" still parses to 0.0, so legitimate (0,0) points survive.
                lat = Double(attrs["lat"] ?? "")
                lon = Double(attrs["lon"] ?? "")
                ele = nil; time = nil
            }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { buffer += s }
        func parser(_ p: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
            switch el {
            case "ele": ele = Double(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
            case "time": time = iso.date(from: buffer.trimmingCharacters(in: .whitespacesAndNewlines))
            case "trkpt":
                // Skip incomplete trackpoints instead of fabricating data. A missing
                // lat/lon would otherwise become (0,0) ("null island"), injecting a
                // bogus transcontinental segment; a missing/unparseable timestamp
                // would become the 1970 epoch, creating a ~50-year `dt` that wrecks
                // moving time and average speed in RideStatsCalculator. Elevation
                // stays optional by contract, so its absence does not skip the point.
                guard let lat, let lon, let time else { break }
                current?.append(TrackPoint(coordinate: Coordinate(latitude: lat, longitude: lon),
                                           elevation: ele, timestamp: time))
            case "trkseg":
                closeCurrentSegment()
            default: break
            }
        }

        /// Drops segments that produced no usable point: an empty `<trkseg>` carries no
        /// information, and emitting it would make `segments.count` depend on GPX authoring
        /// noise rather than on real pauses.
        ///
        /// Consequence, stated so a later pass does not trip over it: an EMPTY segment can
        /// never be produced through GPX, so `PausedGoldenRideFixture` cannot exercise the
        /// pause-before-first-fix or pause→resume→pause states that spec D6 makes legal.
        /// Pass 2 owns synthesizing those at the recorder; the per-segment `count >= 2`
        /// guard is unit-tested directly in `RideStatsSegmentTests`.
        private func closeCurrentSegment() {
            if let current, !current.isEmpty { segments.append(current) }
            current = nil
        }

        func parserDidEndDocument(_ parser: XMLParser) { closeCurrentSegment() }
    }
}
