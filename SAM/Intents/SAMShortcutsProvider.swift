import AppIntents

struct SAMShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PrepForMeetingIntent(),
            phrases: [
                "Prep me for my next meeting in \(.applicationName)",
                "Brief me on my next meeting in \(.applicationName)",
                "What's my next meeting in \(.applicationName)",
            ],
            shortTitle: "Meeting Prep",
            systemImageName: "calendar.badge.clock"
        )

        AppShortcut(
            intent: WhoToReachOutIntent(),
            phrases: [
                "Who should I reach out to in \(.applicationName)",
                "Who am I overdue to contact in \(.applicationName)",
                "Show overdue contacts in \(.applicationName)",
            ],
            shortTitle: "Reach Out",
            systemImageName: "person.wave.2"
        )

        AppShortcut(
            intent: NextActionIntent(),
            phrases: [
                "What should I do next in \(.applicationName)",
                "What's my next action in \(.applicationName)",
                "Show my top priority in \(.applicationName)",
            ],
            shortTitle: "Next Action",
            systemImageName: "checklist"
        )

        AppShortcut(
            intent: DailyBriefingIntent(),
            phrases: [
                "Give me my briefing in \(.applicationName)",
                "Show my daily briefing in \(.applicationName)",
                "Morning briefing in \(.applicationName)",
            ],
            shortTitle: "Daily Briefing",
            systemImageName: "sun.horizon"
        )

        AppShortcut(
            intent: FindPersonIntent(),
            phrases: [
                "Find \(\.$person) in \(.applicationName)",
                "Look up \(\.$person) in \(.applicationName)",
                "Show \(\.$person) in \(.applicationName)",
            ],
            shortTitle: "Find Person",
            systemImageName: "person.circle"
        )
    }
}
