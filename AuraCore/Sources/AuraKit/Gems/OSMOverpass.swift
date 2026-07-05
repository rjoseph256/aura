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

    public static func elements(from data: Data) -> [(id: String, name: String?, coordinate: Coordinate, tags: [String: String])] {
        struct Response: Decodable { let elements: [Element] }
        struct Element: Decodable { let type: String; let id: Int; let lat: Double?; let lon: Double?; let tags: [String: String]? }
        guard let resp = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return resp.elements.compactMap { e in
            guard let lat = e.lat, let lon = e.lon else { return nil }   // nodes only (ways lack lat/lon here)
            let tags = e.tags ?? [:]
            return (id: "osm:\(e.type)/\(e.id)", name: tags["name"],
                    coordinate: Coordinate(latitude: lat, longitude: lon), tags: tags)
        }
    }
}
