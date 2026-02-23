//
//  CoachingAdvisor.swift
//  SAM
//
//  Created by Assistant on 2/22/26.
//  Phase N: Outcome-Focused Coaching Engine
//
//  Analyzes user feedback to improve outcome quality and coaching style.
//  Tracks implicit signals (acted on, dismissed, response time) and explicit ratings.
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "CoachingAdvisor")

@MainActor
@Observable
final class CoachingAdvisor {

    // MARK: - Singleton

    static let shared = CoachingAdvisor()

    // MARK: - Container

    private var container: ModelContainer?
    private var context: ModelContext?

    private init() {}

    func configure(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
    }

    // MARK: - Encouragement Styles

    static let styles = ["direct", "supportive", "achievement", "analytical"]

    // MARK: - Profile Access

    /// Fetch or create the singleton coaching profile.
    func fetchOrCreateProfile() throws -> CoachingProfile {
        guard let context else {
            throw CoachingError.notConfigured
        }

        let descriptor = FetchDescriptor<CoachingProfile>()
        let profiles = try context.fetch(descriptor)

        if let existing = profiles.first {
            return existing
        }

        let profile = CoachingProfile()
        context.insert(profile)
        try context.save()
        return profile
    }

    // MARK: - Feedback Analysis

    /// Analyze completed/dismissed outcomes and update the coaching profile.
    func updateProfile() throws {
        guard let context else { throw CoachingError.notConfigured }

        let profile = try fetchOrCreateProfile()

        let descriptor = FetchDescriptor<SamOutcome>()
        let allOutcomes = try context.fetch(descriptor)

        // Count acted-on and dismissed by kind
        var actedOnByKind: [String: Int] = [:]
        var dismissedByKind: [String: Int] = [:]
        var totalActedOn = 0
        var totalDismissed = 0
        var responseTimes: [Double] = []
        var ratings: [Int] = []

        for outcome in allOutcomes {
            switch outcome.status {
            case .completed:
                totalActedOn += 1
                actedOnByKind[outcome.outcomeKindRawValue, default: 0] += 1

                // Response time
                if let surfaced = outcome.lastSurfacedAt, let completed = outcome.completedAt {
                    let minutes = completed.timeIntervalSince(surfaced) / 60
                    if minutes > 0 && minutes < 10080 { // Within 7 days
                        responseTimes.append(minutes)
                    }
                }

                // Rating
                if let rating = outcome.userRating {
                    ratings.append(rating)
                }

            case .dismissed:
                totalDismissed += 1
                dismissedByKind[outcome.outcomeKindRawValue, default: 0] += 1

            default:
                break
            }
        }

        // Update profile
        profile.totalActedOn = totalActedOn
        profile.totalDismissed = totalDismissed
        profile.totalRated = ratings.count
        profile.avgRating = ratings.isEmpty ? 0 : Double(ratings.reduce(0, +)) / Double(ratings.count)
        profile.avgResponseTimeMinutes = responseTimes.isEmpty ? 0 : responseTimes.reduce(0, +) / Double(responseTimes.count)

        // Preferred kinds (sorted by acted-on count, top 3)
        profile.preferredOutcomeKinds = actedOnByKind
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map(\.key)

        // Dismiss patterns (sorted by dismissed count, top 3)
        profile.dismissPatterns = dismissedByKind
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map(\.key)

        profile.updatedAt = .now

        try context.save()
        logger.info("Coaching profile updated: \(totalActedOn) acted, \(totalDismissed) dismissed, avg rating \(profile.avgRating)")
    }

    // MARK: - Encouragement Generation

    /// Generate an encouragement message for a completed outcome.
    func generateEncouragement(for outcome: SamOutcome) async -> String? {
        let profile: CoachingProfile
        do {
            profile = try fetchOrCreateProfile()
        } catch {
            return nil
        }

        let style = profile.encouragementStyle

        // Deterministic encouragement based on style
        switch style {
        case "direct":
            return directEncouragement(for: outcome, profile: profile)
        case "supportive":
            return supportiveEncouragement(for: outcome, profile: profile)
        case "achievement":
            return achievementEncouragement(for: outcome, profile: profile)
        case "analytical":
            return analyticalEncouragement(for: outcome, profile: profile)
        default:
            return directEncouragement(for: outcome, profile: profile)
        }
    }

    /// Decide whether to show a rating prompt (adaptive frequency).
    func shouldRequestRating() -> Bool {
        guard let profile = try? fetchOrCreateProfile() else { return false }

        // More ratings if we have few, less as we accumulate data
        if profile.totalRated < 5 { return true }     // Always ask initially
        if profile.totalRated < 20 { return Int.random(in: 1...3) == 1 }  // 1 in 3
        return Int.random(in: 1...5) == 1  // 1 in 5 once we have enough
    }

    /// Get adjusted priority weights based on user preferences.
    func adjustedWeights() -> OutcomeEngine.OutcomeWeights {
        var weights = OutcomeEngine.OutcomeWeights()

        guard let profile = try? fetchOrCreateProfile() else { return weights }

        // If user responds quickly, boost time urgency weight
        if profile.avgResponseTimeMinutes > 0 && profile.avgResponseTimeMinutes < 60 {
            weights.timeUrgency = 0.35
            weights.evidenceRecency = 0.10
        }

        // If user dismisses a lot, reduce engagement weight
        let total = profile.totalActedOn + profile.totalDismissed
        if total > 10 {
            let actedRatio = Double(profile.totalActedOn) / Double(total)
            if actedRatio < 0.3 {
                // User dismisses most — focus on higher-quality suggestions
                weights.roleImportance = 0.25
                weights.userEngagement = 0.10
            }
        }

        return weights
    }

    // MARK: - Private: Style-Specific Encouragement

    private func directEncouragement(for outcome: SamOutcome, profile: CoachingProfile) -> String {
        let name = outcome.linkedPerson?.displayNameCache ?? outcome.linkedPerson?.displayName
        if let name {
            return "Done. \(name)'s \(outcome.outcomeKind.displayName.lowercased()) is handled."
        }
        return "Done. Moving on."
    }

    private func supportiveEncouragement(for outcome: SamOutcome, profile: CoachingProfile) -> String {
        let kind = outcome.outcomeKind
        switch kind {
        case .followUp:
            return "Great follow-through. That consistency builds trust."
        case .preparation:
            return "Well prepared. You'll walk in confident."
        case .outreach:
            return "Reaching out matters. Relationships grow with attention."
        case .proposal:
            return "Strong work putting that together."
        default:
            return "Nice work. Keep the momentum going."
        }
    }

    private func achievementEncouragement(for outcome: SamOutcome, profile: CoachingProfile) -> String {
        let completedToday = profile.totalActedOn  // Simplified — could track daily
        if completedToday > 0 && completedToday % 5 == 0 {
            return "That's \(completedToday) outcomes completed. Impressive track record."
        }
        return "Another one done. You're on a roll."
    }

    private func analyticalEncouragement(for outcome: SamOutcome, profile: CoachingProfile) -> String {
        if profile.avgResponseTimeMinutes > 0 {
            let avgMin = Int(profile.avgResponseTimeMinutes)
            return "Completed in your typical timeframe (~\(avgMin) min avg). Efficient."
        }
        return "Outcome completed. Pattern tracking in progress."
    }

    // MARK: - Errors

    enum CoachingError: Error, LocalizedError {
        case notConfigured

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "CoachingAdvisor not configured — call configure(container:) first"
            }
        }
    }
}
