import AppIntents
import SwiftData

// MARK: - Person Entity

struct PersonEntity: AppEntity, Sendable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Person"
    static var defaultQuery = PersonEntityQuery()

    var id: UUID
    var name: String
    var email: String?
    var role: String?
    var daysSinceInteraction: Int?
    var healthStatus: String?

    var displayRepresentation: DisplayRepresentation {
        var subtitle: String?
        if let role {
            subtitle = role
        }
        return DisplayRepresentation(
            title: "\(name)",
            subtitle: subtitle.map { LocalizedStringResource(stringLiteral: $0) },
            image: .init(systemName: "person.circle")
        )
    }
}

// MARK: - Person Entity Query

struct PersonEntityQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [PersonEntity] {
        try await MainActor.run {
            identifiers.compactMap { id in
                guard let person = try? PeopleRepository.shared.fetch(id: id) else {
                    return nil
                }
                return person.toEntity()
            }
        }
    }

    func suggestedEntities() async throws -> [PersonEntity] {
        try await MainActor.run {
            let all = try PeopleRepository.shared.fetchAll()
            return Array(
                all.filter { !$0.isArchived && !$0.isMe }
                    .prefix(10)
                    .map { $0.toEntity() }
            )
        }
    }

    func entities(matching string: String) async throws -> [PersonEntity] {
        try await MainActor.run {
            let results = try PeopleRepository.shared.search(query: string)
            return results
                .filter { !$0.isArchived && !$0.isMe }
                .map { $0.toEntity() }
        }
    }
}

// MARK: - SamPerson → PersonEntity Conversion

@MainActor
extension SamPerson {
    func toEntity() -> PersonEntity {
        let health = MeetingPrepCoordinator.shared.computeHealth(for: self)
        return PersonEntity(
            id: id,
            name: displayNameCache ?? displayName,
            email: emailCache ?? email,
            role: roleBadges.first,
            daysSinceInteraction: health.daysSinceLastInteraction,
            healthStatus: health.statusLabel
        )
    }
}
