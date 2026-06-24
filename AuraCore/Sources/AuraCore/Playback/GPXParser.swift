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
        private var lat = 0.0, lon = 0.0
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
                lat = Double(attrs["lat"] ?? "") ?? 0
                lon = Double(attrs["lon"] ?? "") ?? 0
                ele = nil; time = nil
            }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { buffer += s }
        func parser(_ p: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
            switch el {
            case "ele": ele = Double(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
            case "time": time = Self.iso.date(from: buffer.trimmingCharacters(in: .whitespacesAndNewlines))
            case "trkpt":
                points.append(TrackPoint(coordinate: Coordinate(latitude: lat, longitude: lon),
                                         elevation: ele, timestamp: time ?? Date(timeIntervalSince1970: 0)))
            default: break
            }
        }
    }
}
