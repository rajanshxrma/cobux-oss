import SwiftData
import Foundation

@Model
final class Theme {
    var id: UUID = UUID()
    var name: String
    var themeDescription: String
    var relatedThemeNames: [String]
    var dateGenerated: Date

    @Relationship(inverse: \Highlight.themes)
    var highlights: [Highlight] = []

    init(name: String, themeDescription: String = "", relatedThemeNames: [String] = [], dateGenerated: Date = .now) {
        self.id = UUID()
        self.name = name
        self.themeDescription = themeDescription
        self.relatedThemeNames = relatedThemeNames
        self.dateGenerated = dateGenerated
    }
}
