import Foundation

public enum GPXParser {
    public enum ParseError: Error { case invalidXML }

    public static func parse(_ xml: String) throws -> GPXTrack {
        guard let data = xml.data(using: .utf8) else { throw ParseError.invalidXML }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw ParseError.invalidXML }
        return GPXTrack(points: delegate.points)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var points: [TrackPoint] = []
        private var lat: Double?
        private var lon: Double?
        private var ele: Double?
        private var time: Date?
        private var buffer = ""
        private static let iso: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
        }()

        func parser(_ p: XMLParser, didStartElement el: String, namespaceURI: String?,
                    qualifiedName: String?, attributes attrs: [String: String]) {
            buffer = ""
            if el == "trkpt" {
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
            case "time": time = Self.iso.date(from: buffer.trimmingCharacters(in: .whitespacesAndNewlines))
            case "trkpt":
                // Skip incomplete trackpoints instead of fabricating data. A missing
                // lat/lon would otherwise become (0,0) ("null island"), injecting a
                // bogus transcontinental segment; a missing/unparseable timestamp
                // would become the 1970 epoch, creating a ~50-year `dt` that wrecks
                // moving time and average speed in RideStatsCalculator. Elevation
                // stays optional by contract, so its absence does not skip the point.
                guard let lat, let lon, let time else { break }
                points.append(TrackPoint(coordinate: Coordinate(latitude: lat, longitude: lon),
                                         elevation: ele, timestamp: time))
            default: break
            }
        }
    }
}
