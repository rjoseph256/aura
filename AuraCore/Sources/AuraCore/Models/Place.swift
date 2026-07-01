import Foundation

public struct Place: Identifiable, Codable, Equatable, Sendable {
    public enum Category: String, Codable, Sendable {
        case brewery, trailhead, address, custom
    }
    public var id: UUID
    public var name: String
    public var subtitle: String?
    public var coordinate: Coordinate
    public var category: Category
    public var isSaved: Bool

    public init(id: UUID = UUID(), name: String, subtitle: String? = nil,
                coordinate: Coordinate, category: Category, isSaved: Bool = false) {
        self.id = id; self.name = name; self.subtitle = subtitle
        self.coordinate = coordinate; self.category = category; self.isSaved = isSaved
    }
}
