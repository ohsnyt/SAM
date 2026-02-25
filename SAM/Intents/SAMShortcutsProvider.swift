import AppIntents

struct SAMShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PrepForMeetingIntent(),
            phrases: [
                "Prep me for my next meeting in \(.applicationName)",
                "Brief me on my next meeting in \(.applicationName)",
                "Get my meeting prep in \(.applicationName)",
            ],
            shortTitle: "Meeting Prep",
            systemImageName: "calendar.badge.clock"
        )

        AppShortcut(
            intent: DailyBriefingIntent(),
            phrases: [
                "Start my briefing in \(.applicationName)",
                "Pull up my briefing in \(.applicationName)",
                "Run my briefing in \(.applicationName)",
            ],
            shortTitle: "Daily Briefing",
            systemImageName: "sun.horizon"
        )

        AppShortcut(
            intent: NextActionIntent(),
            phrases: [
                "Get my next action in \(.applicationName)",
                "Check my next action in \(.applicationName)",
                "Pull up my top priority in \(.applicationName)",
            ],
            shortTitle: "Next Action",
            systemImageName: "checklist"
        )

        AppShortcut(
            intent: WhoToReachOutIntent(),
            phrases: [
                "Check overdue contacts in \(.applicationName)",
                "List overdue contacts in \(.applicationName)",
                "Get my overdue contacts in \(.applicationName)",
            ],
            shortTitle: "Reach Out",
            systemImageName: "person.wave.2"
        )

        AppShortcut(
            intent: FindPersonIntent(),
            phrases: [
                "Find \(\.$person) in \(.applicationName)",
                "Look up \(\.$person) in \(.applicationName)",
                "Search for \(\.$person) in \(.applicationName)",
            ],
            shortTitle: "Find Person",
            systemImageName: "person.circle"
        )
    }
}
