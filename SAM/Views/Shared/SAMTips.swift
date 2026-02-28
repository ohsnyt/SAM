//
//  SAMTips.swift
//  SAM
//
//  Phase AB: In-App Guidance — TipKit tip definitions and global toggle state
//

import TipKit
import SwiftUI

// MARK: - Global Guidance Toggle

/// Shared state for the guidance system. All tips check `guidanceEnabled`
/// via a TipKit `@Parameter` rule so they hide/show immediately when toggled.
enum SAMTipState {
    @Parameter
    static var guidanceEnabled: Bool = true
}

// MARK: - Today View Tips

struct TodayHeroCardTip: Tip {
    var title: Text { Text("Your Top Priority") }
    var message: Text? {
        Text("This card shows SAM's highest-priority coaching recommendation. Act on it, mark it done, or skip to see the next one.")
    }
    var image: Image? { Image(systemName: "star.fill") }

    var options: [any TipOption] {
        MaxDisplayCount(1)
    }
    var rules: [Rule] {
        #Rule(SAMTipState.$guidanceEnabled) { $0 == true }
    }
}

struct OutcomeQueueTip: Tip {
    var title: Text { Text("Your Action Queue") }
    var message: Text? {
        Text("SAM generates coaching outcomes throughout the day. Each tells you what to do and why. Tap Done when complete, or Skip to dismiss.")
    }
    var image: Image? { Image(systemName: "checklist") }

    var options: [any TipOption] {
        MaxDisplayCount(1)
    }
    var rules: [Rule] {
        #Rule(SAMTipState.$guidanceEnabled) { $0 == true }
    }
}

struct BriefingButtonTip: Tip {
    var title: Text { Text("Daily Briefing") }
    var message: Text? {
        Text("Tap here to review today's briefing anytime. SAM prepares a new one each morning with your schedule, priorities, and follow-ups.")
    }
    var image: Image? { Image(systemName: "text.book.closed") }

    var options: [any TipOption] {
        MaxDisplayCount(1)
    }
    var rules: [Rule] {
        #Rule(SAMTipState.$guidanceEnabled) { $0 == true }
    }
}

// MARK: - People Tips

struct PeopleListTip: Tip {
    var title: Text { Text("Your Relationships") }
    var message: Text? {
        Text("Everyone SAM tracks appears here. Health indicators show relationship status — green means active, orange means attention needed, red means at risk.")
    }
    var image: Image? { Image(systemName: "person.2") }

    var options: [any TipOption] {
        MaxDisplayCount(1)
    }
    var rules: [Rule] {
        #Rule(SAMTipState.$guidanceEnabled) { $0 == true }
    }
}

struct PersonCoachingTip: Tip {
    var title: Text { Text("Coaching Preview") }
    var message: Text? {
        Text("SAM summarizes each person's status and recommends next steps. Scroll down for evidence history, notes, and pipeline details.")
    }
    var image: Image? { Image(systemName: "brain.head.profile") }

    var options: [any TipOption] {
        MaxDisplayCount(1)
    }
    var rules: [Rule] {
        #Rule(SAMTipState.$guidanceEnabled) { $0 == true }
    }
}

// MARK: - Notes Tips

struct AddNoteTip: Tip {
    var title: Text { Text("Capture Notes") }
    var message: Text? {
        Text("After meetings or calls, add a note here. SAM analyzes it for action items, life events, and follow-up suggestions. Try the microphone for voice dictation.")
    }
    var image: Image? { Image(systemName: "note.text.badge.plus") }

    var options: [any TipOption] {
        MaxDisplayCount(1)
    }
    var rules: [Rule] {
        #Rule(SAMTipState.$guidanceEnabled) { $0 == true }
    }
}

struct DictationTip: Tip {
    var title: Text { Text("Voice Dictation") }
    var message: Text? {
        Text("Tap the microphone to dictate notes hands-free. SAM transcribes on-device and cleans up grammar automatically.")
    }
    var image: Image? { Image(systemName: "mic.fill") }

    var options: [any TipOption] {
        MaxDisplayCount(1)
    }
    var rules: [Rule] {
        #Rule(SAMTipState.$guidanceEnabled) { $0 == true }
    }
}

// MARK: - Business Dashboard Tips

struct BusinessDashboardTip: Tip {
    var title: Text { Text("Business Intelligence") }
    var message: Text? {
        Text("This dashboard shows your practice at a glance: pipeline health, production metrics, strategic insights, and goals. Use the tabs to explore each area.")
    }
    var image: Image? { Image(systemName: "chart.bar.horizontal.page") }

    var options: [any TipOption] {
        MaxDisplayCount(1)
    }
    var rules: [Rule] {
        #Rule(SAMTipState.$guidanceEnabled) { $0 == true }
    }
}

struct StrategicInsightsTip: Tip {
    var title: Text { Text("Strategic Insights") }
    var message: Text? {
        Text("SAM analyzes your pipeline, time allocation, and relationship patterns to generate strategic recommendations. These refresh automatically in the background.")
    }
    var image: Image? { Image(systemName: "lightbulb.max") }

    var options: [any TipOption] {
        MaxDisplayCount(1)
    }
    var rules: [Rule] {
        #Rule(SAMTipState.$guidanceEnabled) { $0 == true }
    }
}

struct GoalsTip: Tip {
    var title: Text { Text("Business Goals") }
    var message: Text? {
        Text("Define targets like \"Write 10 policies this quarter\" or \"Recruit 3 agents this month.\" SAM tracks your pace and adjusts coaching to help you hit your goals.")
    }
    var image: Image? { Image(systemName: "flag.fill") }

    var options: [any TipOption] {
        MaxDisplayCount(1)
    }
    var rules: [Rule] {
        #Rule(SAMTipState.$guidanceEnabled) { $0 == true }
    }
}

// MARK: - Navigation Tips

struct CommandPaletteTip: Tip {
    var title: Text { Text("Quick Navigation") }
    var message: Text? {
        Text("Press ⌘K to open the command palette for fast search and navigation. Use ⌘1–4 to jump directly between sections.")
    }
    var image: Image? { Image(systemName: "keyboard") }

    var options: [any TipOption] {
        MaxDisplayCount(1)
    }
    var rules: [Rule] {
        #Rule(SAMTipState.$guidanceEnabled) { $0 == true }
    }
}

struct SearchTip: Tip {
    var title: Text { Text("Search Everything") }
    var message: Text? {
        Text("Search across people, notes, evidence, and outcomes all at once. Use ⌘4 or ⌘K to get here quickly.")
    }
    var image: Image? { Image(systemName: "magnifyingglass") }

    var options: [any TipOption] {
        MaxDisplayCount(1)
    }
    var rules: [Rule] {
        #Rule(SAMTipState.$guidanceEnabled) { $0 == true }
    }
}
