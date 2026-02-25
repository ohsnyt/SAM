import AppIntents
import Foundation

struct FindPersonIntent: AppIntent {
    static var title: LocalizedStringResource = "Find person"
    static var description: IntentDescription = "Look up a person in SAM and navigate to their profile"
    static var openAppWhenRun = true

    @Parameter(title: "Person")
    var person: PersonEntity

    func perform() async throws -> some ProvidesDialog {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .samNavigateToPerson,
                object: nil,
                userInfo: ["personID": person.id]
            )
        }

        var lines: [String] = [person.name]

        if let role = person.role {
            lines.append("Role: \(role)")
        }

        if let health = person.healthStatus {
            lines.append("Status: \(health)")
        }

        if let days = person.daysSinceInteraction {
            lines.append("Last interaction: \(days) days ago")
        }

        return .result(dialog: "\(lines.joined(separator: "\n"))")
    }
}
