import AppIntents

struct PrepForMeetingIntent: AppIntent {
    static var title: LocalizedStringResource = "Prep for next meeting"
    static var description: IntentDescription = "Get a briefing for your next upcoming meeting"
    static var openAppWhenRun = false

    func perform() async throws -> some ProvidesDialog {
        let briefing = await MainActor.run {
            MeetingPrepCoordinator.shared.briefings.first
        }

        await MainActor.run {
            Task { await MeetingPrepCoordinator.shared.refresh() }
        }

        guard let briefing else {
            return .result(dialog: "No upcoming meetings in the next 48 hours.")
        }

        var lines: [String] = []

        // Meeting title and time
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let timeStr = formatter.string(from: briefing.startsAt)
        lines.append("\(briefing.title) at \(timeStr)")

        // Location
        if let location = briefing.location, !location.isEmpty {
            lines.append("Location: \(location)")
        }

        // Attendees
        if !briefing.attendees.isEmpty {
            let names = briefing.attendees.map { $0.displayName }
            lines.append("With: \(names.joined(separator: ", "))")

            // Health summary for each attendee
            for attendee in briefing.attendees {
                let healthLabel = attendee.health.statusLabel
                let roles = attendee.roleBadges.isEmpty ? "" : " (\(attendee.roleBadges.joined(separator: ", ")))"
                lines.append("  \(attendee.displayName)\(roles) — \(healthLabel)")
            }
        }

        // Topics
        if !briefing.topics.isEmpty {
            lines.append("Topics: \(briefing.topics.joined(separator: ", "))")
        }

        // Open action items
        if !briefing.openActionItems.isEmpty {
            lines.append("Open items: \(briefing.openActionItems.count)")
            for item in briefing.openActionItems.prefix(3) {
                lines.append("  - \(item.description)")
            }
        }

        return .result(dialog: "\(lines.joined(separator: "\n"))")
    }
}
