import AppIntents

struct WhoToReachOutIntent: AppIntent {
    static var title: LocalizedStringResource = "Who should I reach out to?"
    static var description: IntentDescription = "Find contacts you're overdue to reach out to"
    static var openAppWhenRun = false

    @Parameter(title: "Role", default: .any)
    var role: RoleFilter

    func perform() async throws -> some ProvidesDialog & ReturnsValue<[PersonEntity]> {
        let results = try await MainActor.run {
            let allPeople = try PeopleRepository.shared.fetchAll()
            let coordinator = MeetingPrepCoordinator.shared

            var overdue: [(person: SamPerson, daysOverdue: Int)] = []

            for person in allPeople {
                guard !person.isArchived, !person.isMe else { continue }

                // Filter by role if specified
                if let badge = role.badgeString {
                    guard person.roleBadges.contains(badge) else { continue }
                }

                let health = coordinator.computeHealth(for: person)
                guard let days = health.daysSinceLastInteraction else { continue }

                let threshold = Self.roleThreshold(for: person.roleBadges.first)
                guard days >= threshold else { continue }

                overdue.append((person: person, daysOverdue: days - threshold))
            }

            // Sort by most overdue first
            overdue.sort { $0.daysOverdue > $1.daysOverdue }

            return Array(overdue.prefix(3).map { $0.person.toEntity() })
        }

        guard !results.isEmpty else {
            return .result(
                value: [],
                dialog: "Everyone is up to date — no overdue contacts."
            )
        }

        var lines: [String] = ["You should reach out to:"]
        for entity in results {
            let role = entity.role ?? "Contact"
            let days = entity.daysSinceInteraction.map { "\($0)d ago" } ?? "no recent contact"
            lines.append("  \(entity.name) (\(role)) — \(days)")
        }

        return .result(
            value: results,
            dialog: "\(lines.joined(separator: "\n"))"
        )
    }

    private static func roleThreshold(for role: String?) -> Int {
        switch role?.lowercased() {
        case "client":           return 45
        case "applicant":        return 14
        case "lead":             return 30
        case "agent":            return 21
        case "referral partner": return 45
        case "external agent":   return 60
        case "vendor":           return 90
        default:                 return 60
        }
    }
}
