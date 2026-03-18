//
//  FeatureAdoptionTracker.swift
//  SAM
//
//  Priority 7: Progressive Feature Coaching
//
//  Lightweight singleton that tracks feature usage milestones via UserDefaults
//  and generates coaching outcomes for underutilized features.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "FeatureAdoptionTracker")

// MARK: - Feature Coaching Suggestion

struct FeatureCoachingSuggestion: Sendable {
    let feature: FeatureAdoptionTracker.Feature
    let title: String
    let rationale: String
    let suggestedNextStep: String
    let guideArticleID: String?
}

@MainActor
@Observable
final class FeatureAdoptionTracker {

    static let shared = FeatureAdoptionTracker()

    // MARK: - Feature Enum

    enum Feature: String, CaseIterable, Sendable {
        case businessDashboard
        case relationshipGraph
        case contentDraft
        case goalSetting
        case deepWorkSchedule
        case substackImport
        case linkedInImport
        case facebookImport
        case postMeetingCapture
        case dictation
        case search
        case clipboardCapture
    }

    // MARK: - Private

    private let defaults = UserDefaults.standard
    private let enabledKey = "sam.coaching.featureAdoptionEnabled"

    var isEnabled: Bool {
        defaults.object(forKey: enabledKey) == nil ? true : defaults.bool(forKey: enabledKey)
    }

    private init() {}

    // MARK: - Usage Recording

    /// Record that a feature was used. Safe to call multiple times — only first use is recorded.
    func recordUsage(_ feature: Feature) {
        let key = "sam.feature.\(feature.rawValue).firstUsedAt"
        guard defaults.double(forKey: key) == 0 else { return }
        defaults.set(Date.now.timeIntervalSince1970, forKey: key)
        logger.debug("Feature first use recorded: \(feature.rawValue)")
    }

    /// Whether a feature has been used at least once.
    func hasUsed(_ feature: Feature) -> Bool {
        defaults.double(forKey: "sam.feature.\(feature.rawValue).firstUsedAt") > 0
    }

    // MARK: - Coaching Suggestions

    /// Get coaching suggestions for features not yet used, gated by days since onboarding.
    /// Returns at most 1 suggestion per call to avoid flooding the outcome queue.
    func suggestionsForUnusedFeatures() -> [FeatureCoachingSuggestion] {
        guard isEnabled else { return [] }

        let onboardingDate = onboardingCompletionDate
        guard let onboardingDate else { return [] }

        let daysSinceOnboarding = Calendar.current.dateComponents([.day], from: onboardingDate, to: .now).day ?? 0

        for entry in coachingTimeline {
            guard daysSinceOnboarding >= entry.dayThreshold else { continue }
            guard !hasUsed(entry.feature) else { continue }
            guard !hasBeenCoached(entry.feature) else { continue }

            // Return only 1 suggestion per cycle
            return [FeatureCoachingSuggestion(
                feature: entry.feature,
                title: entry.title,
                rationale: entry.rationale,
                suggestedNextStep: entry.suggestedNextStep,
                guideArticleID: entry.guideArticleID
            )]
        }

        return []
    }

    /// Mark a feature as having had its coaching outcome created.
    func markCoached(_ feature: Feature) {
        defaults.set(true, forKey: "sam.feature.\(feature.rawValue).coached")
    }

    private func hasBeenCoached(_ feature: Feature) -> Bool {
        defaults.bool(forKey: "sam.feature.\(feature.rawValue).coached")
    }

    private var onboardingCompletionDate: Date? {
        let ts = defaults.double(forKey: "sam.onboarding.completedAt")
        guard ts > 0 else {
            // Fallback: if onboarding is complete but no timestamp, use "now" and save it
            if defaults.bool(forKey: "hasCompletedOnboarding") {
                let now = Date.now.timeIntervalSince1970
                defaults.set(now, forKey: "sam.onboarding.completedAt")
                return .now
            }
            return nil
        }
        return Date(timeIntervalSince1970: ts)
    }

    // MARK: - Coaching Timeline

    private struct CoachingEntry {
        let dayThreshold: Int
        let feature: Feature
        let title: String
        let rationale: String
        let suggestedNextStep: String
        let guideArticleID: String?
    }

    private let coachingTimeline: [CoachingEntry] = [
        CoachingEntry(
            dayThreshold: 1,
            feature: .businessDashboard,
            title: "Explore your Business Dashboard",
            rationale: "Your Business Dashboard shows pipeline health, production metrics, and strategic insights — all in one place.",
            suggestedNextStep: "Open Business in the sidebar to see your dashboard",
            guideArticleID: "business.overview"
        ),
        CoachingEntry(
            dayThreshold: 1,
            feature: .relationshipGraph,
            title: "Visualize your network in the Relationship Graph",
            rationale: "The Relationship Graph shows connections between your contacts, helping you spot referral chains and family clusters.",
            suggestedNextStep: "Open People → toggle to Graph view in the toolbar",
            guideArticleID: "people.relationship-graph"
        ),
        CoachingEntry(
            dayThreshold: 2,
            feature: .goalSetting,
            title: "Set your first business goal",
            rationale: "Business goals help SAM track your progress and pace you toward targets like new clients, policies submitted, or meetings held.",
            suggestedNextStep: "Open Business → Goals tab → tap + to create a goal",
            guideArticleID: "business.goals"
        ),
        CoachingEntry(
            dayThreshold: 2,
            feature: .dictation,
            title: "Try voice dictation for faster note capture",
            rationale: "Tap the microphone button on any note to dictate hands-free. SAM cleans up grammar and filler words automatically.",
            suggestedNextStep: "Open a person's detail view and tap the mic button in the note capture area",
            guideArticleID: "getting-started.dictation"
        ),
        CoachingEntry(
            dayThreshold: 3,
            feature: .search,
            title: "Search across all your data with \u{2318}K",
            rationale: "The command palette lets you search people, notes, evidence, and outcomes instantly from anywhere in SAM.",
            suggestedNextStep: "Press \u{2318}K or click Search in the sidebar",
            guideArticleID: "search.overview"
        ),
        CoachingEntry(
            dayThreshold: 5,
            feature: .substackImport,
            title: "Connect your Substack for audience insights",
            rationale: "Import your Substack subscriber list to find warm leads already in your contacts, and get AI-powered content coaching.",
            suggestedNextStep: "Use File → Import → Substack",
            guideArticleID: "grow.social-imports"
        ),
        CoachingEntry(
            dayThreshold: 5,
            feature: .linkedInImport,
            title: "Import LinkedIn connections",
            rationale: "Import your LinkedIn connections CSV to match existing contacts and discover potential leads in your network.",
            suggestedNextStep: "Use File → Import → LinkedIn",
            guideArticleID: "grow.social-imports"
        ),
        CoachingEntry(
            dayThreshold: 7,
            feature: .facebookImport,
            title: "Import Facebook friends to find warm leads",
            rationale: "Your Facebook friends list often contains warm leads. Import it to match contacts and surface relationship opportunities.",
            suggestedNextStep: "Use File → Import → Facebook",
            guideArticleID: "grow.social-imports"
        ),
        CoachingEntry(
            dayThreshold: 2,
            feature: .postMeetingCapture,
            title: "Capture meeting notes right after meetings",
            rationale: "SAM prompts you after meetings end with talking points and pending actions from the briefing, so you can capture key takeaways while they're fresh.",
            suggestedNextStep: "After your next meeting ends, look for the capture prompt in Today",
            guideArticleID: "people.adding-notes"
        ),
        CoachingEntry(
            dayThreshold: 3,
            feature: .contentDraft,
            title: "Draft social media content with AI",
            rationale: "SAM can generate platform-aware drafts for LinkedIn, Facebook, Instagram, or Substack based on your recent client interactions and business themes.",
            suggestedNextStep: "Open the content draft sheet from a coaching card or the Grow section",
            guideArticleID: "grow.content-drafts"
        ),
        CoachingEntry(
            dayThreshold: 4,
            feature: .deepWorkSchedule,
            title: "Schedule deep work blocks on your calendar",
            rationale: "Protect focused time for important tasks like case prep, training, or strategic planning by scheduling deep work blocks directly from SAM.",
            suggestedNextStep: "Tap a deep work coaching card to schedule a block on your calendar",
            guideArticleID: nil
        ),
        CoachingEntry(
            dayThreshold: 7,
            feature: .clipboardCapture,
            title: "Capture conversations with \u{2303}\u{21e7}V",
            rationale: "Copy a conversation from any messaging app and press \u{2303}\u{21e7}V to save it as relationship evidence in SAM.",
            suggestedNextStep: "Copy a conversation, then press \u{2303}\u{21e7}V",
            guideArticleID: "getting-started.clipboard-capture"
        ),
    ]
}
