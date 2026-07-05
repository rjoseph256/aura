import Foundation
import AuraCore

/// Overpass QL request building + JSON decode for the live feed. No networking here —
/// `LiveGemProvider` performs the URLSession call and feeds `elements(from:)`.
public enum OSMOverpass {
    public static let defaultEndpoint = URL(string: "https://overpass-api.de/api/interpreter")!

    /// Nodes carrying any of the mapped keys within `radiusMeters` of the point.
    public static func query(near c: Coordinate, radiusMeters: Double) -> String {
        let r = Int(radiusMeters)
        let lat = c.latitude, lon = c.longitude
        let filters = ["tourism", "leisure", "amenity", "natural", "historic"]
            .map { "node[\($0)](around:\(r),\(lat),\(lon));" }
            .joined()
        return "[out:json][timeout:10];(\(filters));out center 60;"
    }

    public static func request(near c: Coordinate, radiusMeters: Double,
                               endpoint: URL = defaultEndpoint) -> URLRequest {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.httpBody = Data("data=\(query(near: c, radiusMeters: radiusMeters))".utf8)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        return req
    }

    public static func elements(from data: Data) -> [OSMElement] {
        struct Response: Decodable { let elements: [Element] }
        struct Element: Decodable { let type: String; let id: Int; let lat: Double?; let lon: Double?; let tags: [String: String]? }
        guard let resp = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return resp.elements.compactMap { e in
            guard let lat = e.lat, let lon = e.lon else { return nil }   // nodes only (ways lack lat/lon here)
            let tags = e.tags ?? [:]
            return OSMElement(id: "osm:\(e.type)/\(e.id)", name: tags["name"],
                               coordinate: Coordinate(latitude: lat, longitude: lon), tags: tags)
        }
    }
}

/// A decoded Overpass node: its identity, optional display name, location, and raw OSM tags.
public struct OSMElement: Sendable {
    public let id: String
    public let name: String?
    public let coordinate: Coordinate
    public let tags: [String: String]
    public init(id: String, name: String?, coordinate: Coordinate, tags: [String: String]) {
        self.id = id; self.name = name; self.coordinate = coordinate; self.tags = tags
    }
}
