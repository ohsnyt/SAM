import AppIntents

struct NextActionIntent: AppIntent {
    static var title: LocalizedStringResource = "What should I do next?"
    static var description: IntentDescription = "Get your top priority action item"
    static var openAppWhenRun = false

    func perform() async throws -> some ProvidesDialog {
        let summary = try await MainActor.run {
            guard let outcome = try OutcomeRepository.shared.fetchActive().first else {
                return nil as OutcomeSummary?
            }
            return OutcomeSummary(
                title: outcome.title,
                rationale: outcome.rationale,
                suggestedNextStep: outcome.suggestedNextStep,
                deadlineDate: outcome.deadlineDate
            )
        }

        guard let summary else {
            return .result(dialog: "No active action items right now. You're all caught up!")
        }

        var lines: [String] = [summary.title]

        if !summary.rationale.isEmpty {
            lines.append(summary.rationale)
        }

        if let nextStep = summary.suggestedNextStep, !nextStep.isEmpty {
            lines.append("Next step: \(nextStep)")
        }

        if let deadline = summary.deadlineDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            let relative = formatter.localizedString(for: deadline, relativeTo: Date())
            lines.append("Due \(relative)")
        }

        return .result(dialog: "\(lines.joined(separator: "\n"))")
    }
}

private struct OutcomeSummary: Sendable {
    let title: String
    let rationale: String
    let suggestedNextStep: String?
    let deadlineDate: Date?
}
