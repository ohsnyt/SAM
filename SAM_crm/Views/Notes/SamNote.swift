import Foundation
import SwiftData

@Model
public final class SamNote {
    public var id: UUID
    public var createdAt: Date
    public var text: String
    @Relationship
    public var people: [SamPerson]

    public init(id: UUID = UUID(), createdAt: Date = Date(), text: String, people: [SamPerson] = []) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.people = people
    }
}

// NOTE: Ensure `SamNote` is added to the app's ModelContainer schema elsewhere.
