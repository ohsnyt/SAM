//
//  SAMTips.swift
//  SAM
//
//  Phase AB: In-App Guidance — TipKit tip definitions, custom style, and global toggle state
//

import TipKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "SAMTips")

// MARK: - Global Guidance Toggle

/// Manages the guidance system's on/off state and tip lifecycle.
/// Uses UserDefaults for the toggle (SwiftUI-observable via @AppStorage)
/// and TipKit's invalidate/resetEligibility for runtime control.
enum SAMTipState {

    private static let enabledKey = "sam.tips.guidanceEnabled"

    /// Whether tips are currently enabled. Persisted in UserDefaults.
    static var guidanceEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// All tip types in the app, used for batch operations.
    static let allTipTypes: [any Tip.Type] = [
        TodayHeroCardTip.self,
        OutcomeQueueTip.self,
        BriefingButtonTip.self,
        PeopleListTip.self,
        PersonCoachingTip.self,
        AddNoteTip.self,
        DictationTip.self,
        BusinessDashboardTip.self,
        StrategicInsightsTip.self,
        GoalsTip.self,
        ClientPipelineTip.self,
        RecruitingPipelineTip.self,
        ProductionTip.self,
        RelationshipGraphTip.self,
        SearchTip.self,
        RefreshAnalysisTip.self,
    ]

    /// Turn tips on: reset eligibility for all tips so they reappear.
    @MainActor
    static func enableTips() {
        guidanceEnabled = true
        Task {
            // Reset each tip's eligibility so dismissed tips reappear
            await TodayHeroCardTip().resetEligibility()
            await OutcomeQueueTip().resetEligibility()
            await BriefingButtonTip().resetEligibility()
            await PeopleListTip().resetEligibility()
            await PersonCoachingTip().resetEligibility()
            await AddNoteTip().resetEligibility()
            await DictationTip().resetEligibility()
            await BusinessDashboardTip().resetEligibility()
            await StrategicInsightsTip().resetEligibility()
            await GoalsTip().resetEligibility()
            await ClientPipelineTip().resetEligibility()
            await RecruitingPipelineTip().resetEligibility()
            await ProductionTip().resetEligibility()
            await RelationshipGraphTip().resetEligibility()
            await SearchTip().resetEligibility()
            await RefreshAnalysisTip().resetEligibility()
            logger.info("All tips re-enabled via resetEligibility")
        }
    }

    /// Turn tips off: invalidate all tips so they hide immediately.
    @MainActor
    static func disableTips() {
        guidanceEnabled = false
        TodayHeroCardTip().invalidate(reason: .tipClosed)
        OutcomeQueueTip().invalidate(reason: .tipClosed)
        BriefingButtonTip().invalidate(reason: .tipClosed)
        PeopleListTip().invalidate(reason: .tipClosed)
        PersonCoachingTip().invalidate(reason: .tipClosed)
        AddNoteTip().invalidate(reason: .tipClosed)
        DictationTip().invalidate(reason: .tipClosed)
        BusinessDashboardTip().invalidate(reason: .tipClosed)
        StrategicInsightsTip().invalidate(reason: .tipClosed)
        GoalsTip().invalidate(reason: .tipClosed)
        ClientPipelineTip().invalidate(reason: .tipClosed)
        RecruitingPipelineTip().invalidate(reason: .tipClosed)
        ProductionTip().invalidate(reason: .tipClosed)
        RelationshipGraphTip().invalidate(reason: .tipClosed)
        SearchTip().invalidate(reason: .tipClosed)
        RefreshAnalysisTip().invalidate(reason: .tipClosed)
        logger.info("All tips disabled via invalidate")
    }

    /// Full reset: wipe TipKit datastore and reconfigure. Use for "Reset All Tips".
    @MainActor
    static func resetAllTips() {
        do {
            try Tips.resetDatastore()
            try Tips.configure([
                .displayFrequency(.immediate)
            ])
            guidanceEnabled = true
            logger.info("TipKit datastore reset and reconfigured")
        } catch {
            logger.error("TipKit reset failed: \(error)")
        }
    }
}

// MARK: - Custom Tip View Style

/// A highly visible tip style using Liquid Glass with an amber tint.
/// Designed to stand out clearly against any background.
struct SAMTipViewStyle: TipViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .top, spacing: 12) {
            configuration.image?
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.orange, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                configuration.title?
                    .font(.headline)

                configuration.message?
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button {
                configuration.tip.invalidate(reason: .tipClosed)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .glassEffect(.regular.tint(.orange), in: .rect(cornerRadius: 14))
    }
}

// MARK: - Today View Tips

struct TodayHeroCardTip: Tip {
    var title: Text { Text("Your Top Priority") }
    var message: Text? {
        Text("This card shows SAM's highest-priority coaching recommendation. Act on it, mark it done, or skip to see the next one.")
    }
    var image: Image? { Image(systemName: "star.fill") }
}

struct OutcomeQueueTip: Tip {
    var title: Text { Text("Your Action Queue") }
    var message: Text? {
        Text("SAM generates coaching outcomes throughout the day. Each tells you what to do and why. Tap Done when complete, or Skip to dismiss.")
    }
    var image: Image? { Image(systemName: "checklist") }
}

struct BriefingButtonTip: Tip {
    var title: Text { Text("Daily Briefing") }
    var message: Text? {
        Text("Today's schedule & priorities.")
    }
    var image: Image? { Image(systemName: "text.book.closed") }
}

// MARK: - People Tips

struct PeopleListTip: Tip {
    var title: Text { Text("Your Relationships") }
    var message: Text? {
        Text("Everyone SAM tracks appears here. Health indicators show relationship status \u{2014} green means active, orange means attention needed, red means at risk.")
    }
    var image: Image? { Image(systemName: "person.2") }
}

struct PersonCoachingTip: Tip {
    var title: Text { Text("Coaching Preview") }
    var message: Text? {
        Text("SAM summarizes each person's status and recommends next steps. Scroll down for evidence history, notes, and pipeline details.")
    }
    var image: Image? { Image(systemName: "brain.head.profile") }
}

// MARK: - Notes Tips

struct AddNoteTip: Tip {
    var title: Text { Text("Capture Notes") }
    var message: Text? {
        Text("After meetings or calls, add a note here. SAM analyzes it for action items, life events, and follow-up suggestions. Try the microphone for voice dictation.")
    }
    var image: Image? { Image(systemName: "note.text.badge.plus") }
}

struct DictationTip: Tip {
    var title: Text { Text("Voice Dictation") }
    var message: Text? {
        Text("Tap the microphone to dictate notes hands-free. SAM transcribes on-device and cleans up grammar automatically.")
    }
    var image: Image? { Image(systemName: "mic.fill") }
}

// MARK: - Business Dashboard Tips

struct BusinessDashboardTip: Tip {
    var title: Text { Text("Business Intelligence") }
    var message: Text? {
        Text("This dashboard shows your practice at a glance: pipeline health, production metrics, strategic insights, and goals. Use the tabs to explore each area.")
    }
    var image: Image? { Image(systemName: "chart.bar.horizontal.page") }
}

struct StrategicInsightsTip: Tip {
    var title: Text { Text("Strategic Insights") }
    var message: Text? {
        Text("This view has six sections: Scenario Projections, Strategic Actions, Pipeline Health, Time Balance, Patterns, and Content Ideas. Scroll down to explore each one. Use the Refresh button to regenerate analysis from your latest data.")
    }
    var image: Image? { Image(systemName: "lightbulb.max") }
}

struct RefreshAnalysisTip: Tip {
    var title: Text { Text("Refresh Analysis") }
    var message: Text? {
        Text("Tap regenerate.")
    }
    var image: Image? { Image(systemName: "arrow.clockwise") }
}

struct GoalsTip: Tip {
    var title: Text { Text("Business Goals") }
    var message: Text? {
        Text("Define targets like \"Write 10 policies this quarter\" or \"Recruit 3 agents this month.\" SAM tracks your pace and adjusts coaching to help you hit your goals.")
    }
    var image: Image? { Image(systemName: "flag.fill") }
}

struct ClientPipelineTip: Tip {
    var title: Text { Text("Client Pipeline") }
    var message: Text? {
        Text("Track your client funnel from Lead to Applicant to Client. SAM monitors conversion rates, time-in-stage, and flags people who are stuck so you can take action.")
    }
    var image: Image? { Image(systemName: "person.line.dotted.person") }
}

struct RecruitingPipelineTip: Tip {
    var title: Text { Text("Recruiting Pipeline") }
    var message: Text? {
        Text("Follow recruits through 7 stages from initial conversation to producing agent. SAM tracks licensing rates and alerts you when someone needs a mentoring check-in.")
    }
    var image: Image? { Image(systemName: "person.3.sequence") }
}

struct ProductionTip: Tip {
    var title: Text { Text("Production Tracking") }
    var message: Text? {
        Text("Log policies written, applications submitted, and products sold. SAM shows your product mix, pending aging, and production trends over time.")
    }
    var image: Image? { Image(systemName: "doc.text.badge.checkmark") }
}

struct RelationshipGraphTip: Tip {
    var title: Text { Text("Relationship Map") }
    var message: Text? {
        Text("Visualize your entire network. Drag to pan, scroll to zoom, and click any node to see details. Use the toolbar to filter by role, toggle overlays, and rebuild the layout.")
    }
    var image: Image? { Image(systemName: "circle.grid.cross") }
}

// MARK: - Navigation Tips



struct SearchTip: Tip {
    var title: Text { Text("Search Everything") }
    var message: Text? {
        Text("Search across people, notes, evidence, and outcomes all at once. Use \u{2318}4 or \u{2318}K to get here quickly.")
    }
    var image: Image? { Image(systemName: "magnifyingglass") }
}


