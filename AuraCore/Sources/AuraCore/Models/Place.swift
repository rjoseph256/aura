import Foundation

public struct Place: Identifiable, Codable, Equatable, Sendable {
    public enum Category: String, Codable, Sendable {
        case brewery, trailhead, address, custom
    }
    public var id: UUID
    public var name: String
    public var coordinate: Coordinate
    public var category: Category
    public var isSaved: Bool

    public init(id: UUID = UUID(), name: String, coordinate: Coordinate,
                category: Category, isSaved: Bool = false) {
        self.id = id; self.name = name; self.coordinate = coordinate
        self.category = category; self.isSaved = isSaved
    }
}
