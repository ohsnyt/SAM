//
//  GoalJournalDTO.swift
//  SAM
//
//  Created on March 17, 2026.
//  Goal Journal: Sendable DTO for actor-boundary crossing and team export.
//
//  Mirrors GoalJournalEntry with typed arrays instead of JSON strings.
//  This is the team-sharing payload format — fully self-contained and
//  meaningful without the originating SAM instance's data.
//

import Foundation

// MARK: - GoalJournalEntryDTO

nonisolated public struct GoalJournalEntryDTO: Codable, Sendable, Identifiable {
    public let id: UUID
    public let goalID: UUID
    public let goalTypeRawValue: String
    public let headline: String
    public let whatsWorking: [String]
    public let whatsNotWorking: [String]
    public let barriers: [String]
    public let adjustedStrategy: String?
    public let keyInsight: String?
    public let commitmentActions: [String]
    public let paceAtCheckInRawValue: String
    public let progressAtCheckIn: Double
    public let conversationTurnCount: Int
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        goalID: UUID,
        goalTypeRawValue: String,
        headline: String,
        whatsWorking: [String] = [],
        whatsNotWorking: [String] = [],
        barriers: [String] = [],
        adjustedStrategy: String? = nil,
        keyInsight: String? = nil,
        commitmentActions: [String] = [],
        paceAtCheckInRawValue: String,
        progressAtCheckIn: Double,
        conversationTurnCount: Int = 0,
        createdAt: Date = .now
    ) {
        self.id = id
        self.goalID = goalID
        self.goalTypeRawValue = goalTypeRawValue
        self.headline = headline
        self.whatsWorking = whatsWorking
        self.whatsNotWorking = whatsNotWorking
        self.barriers = barriers
        self.adjustedStrategy = adjustedStrategy
        self.keyInsight = keyInsight
        self.commitmentActions = commitmentActions
        self.paceAtCheckInRawValue = paceAtCheckInRawValue
        self.progressAtCheckIn = progressAtCheckIn
        self.conversationTurnCount = conversationTurnCount
        self.createdAt = createdAt
    }

    // MARK: - Convenience Conversions

    /// Create a DTO from a SwiftData model.
    public init(from entry: GoalJournalEntry) {
        self.id = entry.id
        self.goalID = entry.goalID
        self.goalTypeRawValue = entry.goalTypeRawValue
        self.headline = entry.headline
        self.whatsWorking = entry.whatsWorking
        self.whatsNotWorking = entry.whatsNotWorking
        self.barriers = entry.barriers
        self.adjustedStrategy = entry.adjustedStrategy
        self.keyInsight = entry.keyInsight
        self.commitmentActions = entry.commitmentActions
        self.paceAtCheckInRawValue = entry.paceAtCheckInRawValue
        self.progressAtCheckIn = entry.progressAtCheckIn
        self.conversationTurnCount = entry.conversationTurnCount
        self.createdAt = entry.createdAt
    }

    /// Typed goal type accessor.
    public var goalType: GoalType {
        GoalType(rawValue: goalTypeRawValue) ?? .newClients
    }

    /// Typed pace accessor.
    public var paceAtCheckIn: GoalPace {
        GoalPace(rawValue: paceAtCheckInRawValue) ?? .onTrack
    }
}

// MARK: - GoalCheckInContext

/// Context DTO passed to GoalCheckInService for coaching and summarization.
nonisolated struct GoalCheckInContext: Sendable, Identifiable {
    var id: UUID { goalID }
    let goalID: UUID
    let goalTitle: String
    let goalType: GoalType
    let progress: GoalProgress
    let previousEntries: [GoalJournalEntryDTO]
    let businessSnapshot: String

    init(
        goalID: UUID,
        goalTitle: String,
        goalType: GoalType,
        progress: GoalProgress,
        previousEntries: [GoalJournalEntryDTO] = [],
        businessSnapshot: String = ""
    ) {
        self.goalID = goalID
        self.goalTitle = goalTitle
        self.goalType = goalType
        self.progress = progress
        self.previousEntries = previousEntries
        self.businessSnapshot = businessSnapshot
    }
}
