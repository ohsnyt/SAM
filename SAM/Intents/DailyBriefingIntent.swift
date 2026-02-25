import AppIntents

struct DailyBriefingIntent: AppIntent {
    static var title: LocalizedStringResource = "Give me my briefing"
    static var description: IntentDescription = "Open SAM with your daily briefing"
    static var openAppWhenRun = true

    func perform() async throws -> some ProvidesDialog {
        await MainActor.run {
            Task { await DailyBriefingCoordinator.shared.checkFirstOpenOfDay() }
            DailyBriefingCoordinator.shared.showMorningBriefing = true
        }

        return .result(dialog: "Opening your daily briefing...")
    }
}
