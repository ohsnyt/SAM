//
//  GoalProgressEngine.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase X: Goal Setting & Decomposition
//
//  Computes live goal progress from existing SAM data repositories.
//  Read-only — never writes to any repository.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "GoalProgressEngine")

// MARK: - GoalProgress

/// Snapshot of a goal's current progress and pacing.
struct GoalProgress: Sendable, Identifiable {
    let goalID: UUID
    let goalType: GoalType
    let title: String
    let currentValue: Double
    let targetValue: Double
    let percentComplete: Double
    let pace: GoalPace
    let dailyNeeded: Double
    let weeklyNeeded: Double
    let daysRemaining: Int
    let projectedCompletion: Double

    var id: UUID { goalID }
}

// MARK: - GoalProgressEngine

@MainActor
@Observable
final class GoalProgressEngine {

    // MARK: - Singleton

    static let shared = GoalProgressEngine()

    private init() {}

    // MARK: - Dependencies (read-only)

    private var goalRepo: GoalRepository { GoalRepository.shared }
    private var pipelineRepo: PipelineRepository { PipelineRepository.shared }
    private var productionRepo: ProductionRepository { ProductionRepository.shared }
    private var evidenceRepo: EvidenceRepository { EvidenceRepository.shared }
    private var contentPostRepo: ContentPostRepository { ContentPostRepository.shared }
    private var timeTrackingRepo: TimeTrackingRepository { TimeTrackingRepository.shared }

    // MARK: - Compute Progress

    /// Compute live progress for a single goal.
    func computeProgress(for goal: BusinessGoal) -> GoalProgress {
        let now = Date.now
        let currentValue = measureCurrentValue(for: goal, now: now)
        let targetValue = goal.targetValue

        let percentComplete = targetValue > 0 ? min(currentValue / targetValue, 1.0) : 0

        // Time calculations
        let calendar = Calendar.current
        let totalDays = max(calendar.dateComponents([.day], from: goal.startDate, to: goal.endDate).day ?? 1, 1)
        let elapsedDays = max(calendar.dateComponents([.day], from: goal.startDate, to: now).day ?? 0, 0)
        let daysRemaining = max(calendar.dateComponents([.day], from: now, to: goal.endDate).day ?? 0, 0)

        // Pace calculation
        let elapsedFraction = Double(elapsedDays) / Double(totalDays)
        let pace = computePace(currentValue: currentValue, targetValue: targetValue, elapsedFraction: elapsedFraction)

        // Daily/weekly needed
        let remaining = max(targetValue - currentValue, 0)
        let dailyNeeded = daysRemaining > 0 ? remaining / Double(daysRemaining) : remaining
        let weeksRemaining = Double(daysRemaining) / 7.0
        let weeklyNeeded = weeksRemaining > 0 ? remaining / weeksRemaining : remaining

        // Linear projection
        let projectedCompletion: Double
        if elapsedFraction > 0 {
            projectedCompletion = currentValue / elapsedFraction
        } else {
            projectedCompletion = currentValue
        }

        return GoalProgress(
            goalID: goal.id,
            goalType: goal.goalType,
            title: goal.title,
            currentValue: currentValue,
            targetValue: targetValue,
            percentComplete: percentComplete,
            pace: pace,
            dailyNeeded: dailyNeeded,
            weeklyNeeded: weeklyNeeded,
            daysRemaining: daysRemaining,
            projectedCompletion: projectedCompletion
        )
    }

    /// Compute progress for all active goals.
    func computeAllProgress() -> [GoalProgress] {
        guard let goals = try? goalRepo.fetchActive() else { return [] }
        return goals.map { computeProgress(for: $0) }
    }

    // MARK: - Measurement

    private func measureCurrentValue(for goal: BusinessGoal, now: Date) -> Double {
        let start = goal.startDate
        let end = min(now, goal.endDate)

        switch goal.goalType {
        case .newClients:
            return measureNewClients(start: start, end: end)
        case .policiesSubmitted:
            return measurePoliciesSubmitted(start: start, end: end)
        case .productionVolume:
            return measureProductionVolume(start: start, end: end)
        case .recruiting:
            return measureRecruiting(start: start, end: end)
        case .meetingsHeld:
            return measureMeetingsHeld(start: start, end: end)
        case .contentPosts:
            return measureContentPosts(start: start, end: end)
        case .deepWorkHours:
            return measureDeepWorkHours(start: start, end: end)
        }
    }

    private func measureNewClients(start: Date, end: Date) -> Double {
        guard let transitions = try? pipelineRepo.fetchTransitions(pipelineType: .client, since: start) else { return 0 }
        let count = transitions.filter { t in
            t.toStage.lowercased().contains("client")
            && t.transitionDate >= start
            && t.transitionDate <= end
        }.count
        return Double(count)
    }

    private func measurePoliciesSubmitted(start: Date, end: Date) -> Double {
        guard let records = try? productionRepo.fetchRecords(since: start) else { return 0 }
        let count = records.filter { $0.submittedDate >= start && $0.submittedDate <= end }.count
        return Double(count)
    }

    private func measureProductionVolume(start: Date, end: Date) -> Double {
        guard let records = try? productionRepo.fetchRecords(since: start) else { return 0 }
        return records
            .filter { $0.submittedDate >= start && $0.submittedDate <= end }
            .reduce(0) { $0 + $1.annualPremium }
    }

    private func measureRecruiting(start: Date, end: Date) -> Double {
        guard let transitions = try? pipelineRepo.fetchTransitions(pipelineType: .recruiting, since: start) else { return 0 }
        let count = transitions.filter { t in
            !t.toStage.isEmpty
            && t.transitionDate >= start
            && t.transitionDate <= end
        }.count
        return Double(count)
    }

    private func measureMeetingsHeld(start: Date, end: Date) -> Double {
        guard let allEvidence = try? evidenceRepo.fetchAll() else { return 0 }
        let count = allEvidence.filter {
            $0.source == .calendar
            && $0.occurredAt >= start
            && $0.occurredAt <= end
        }.count
        return Double(count)
    }

    private func measureContentPosts(start: Date, end: Date) -> Double {
        let totalDays = max(Calendar.current.dateComponents([.day], from: start, to: end).day ?? 1, 1)
        guard let posts = try? contentPostRepo.fetchRecent(days: totalDays) else { return 0 }
        let count = posts.filter { $0.postedAt >= start && $0.postedAt <= end }.count
        return Double(count)
    }

    private func measureDeepWorkHours(start: Date, end: Date) -> Double {
        guard let breakdown = try? timeTrackingRepo.categoryBreakdown(from: start, to: end) else { return 0 }
        let deepMinutes = breakdown[.deepWork, default: 0]
        return Double(deepMinutes) / 60.0
    }

    // MARK: - Pace

    private func computePace(currentValue: Double, targetValue: Double, elapsedFraction: Double) -> GoalPace {
        guard targetValue > 0, elapsedFraction > 0 else {
            // Before start or zero target — can't evaluate pace
            return currentValue > 0 ? .ahead : .onTrack
        }

        let expectedProgress = targetValue * elapsedFraction
        let ratio = currentValue / expectedProgress

        switch ratio {
        case 1.1...:       return .ahead
        case 0.9..<1.1:    return .onTrack
        case 0.5..<0.9:    return .behind
        default:           return .atRisk
        }
    }
}
