//
//  SAMModels-GoalJournal.swift
//  SAM
//
//  Created on March 17, 2026.
//  Goal Journal: Persistent check-in learnings for business goals.
//
//  Stores distilled learnings from goal-scoped coaching conversations,
//  not raw transcripts. Team-shareable by design — every field is
//  independently meaningful without the originating SAM database.
//

import SwiftData
import Foundation

// MARK: - GoalJournalEntry

@Model
public final class GoalJournalEntry {
    @Attribute(.unique) public var id: UUID

    /// Links to BusinessGoal (not a @Relationship — survives goal deletion).
    public var goalID: UUID

    /// Snapshot of goal type for portability.
    public var goalTypeRawValue: String

    /// One-line AI-generated summary of check-in.
    public var headline: String

    /// JSON-encoded [String] — strategies producing results.
    public var whatsWorkingJSON: String

    /// JSON-encoded [String] — strategies not producing results.
    public var whatsNotWorkingJSON: String

    /// JSON-encoded [String] — obstacles identified.
    public var barriersJSON: String

    /// New approach decided during session.
    public var adjustedStrategy: String?

    /// Single most important takeaway.
    public var keyInsight: String?

    /// JSON-encoded [String] — specific next actions committed to.
    public var commitmentActionsJSON: String

    /// GoalPace snapshot (ahead/onTrack/behind/atRisk).
    public var paceAtCheckInRawValue: String

    /// Percentage complete at time of check-in (0.0–1.0).
    public var progressAtCheckIn: Double

    /// Number of user+assistant turns for quality assessment.
    public var conversationTurnCount: Int

    public var createdAt: Date

    // MARK: - Transient Typed Accessors

    @Transient
    public var goalType: GoalType {
        get { GoalType(rawValue: goalTypeRawValue) ?? .newClients }
        set { goalTypeRawValue = newValue.rawValue }
    }

    @Transient
    public var paceAtCheckIn: GoalPace {
        get { GoalPace(rawValue: paceAtCheckInRawValue) ?? .onTrack }
        set { paceAtCheckInRawValue = newValue.rawValue }
    }

    @Transient
    public var whatsWorking: [String] {
        get { Self.decodeJSON(whatsWorkingJSON) }
        set { whatsWorkingJSON = Self.encodeJSON(newValue) }
    }

    @Transient
    public var whatsNotWorking: [String] {
        get { Self.decodeJSON(whatsNotWorkingJSON) }
        set { whatsNotWorkingJSON = Self.encodeJSON(newValue) }
    }

    @Transient
    public var barriers: [String] {
        get { Self.decodeJSON(barriersJSON) }
        set { barriersJSON = Self.encodeJSON(newValue) }
    }

    @Transient
    public var commitmentActions: [String] {
        get { Self.decodeJSON(commitmentActionsJSON) }
        set { commitmentActionsJSON = Self.encodeJSON(newValue) }
    }

    // MARK: - Init

    public init(
        id: UUID = UUID(),
        goalID: UUID,
        goalType: GoalType,
        headline: String,
        whatsWorking: [String] = [],
        whatsNotWorking: [String] = [],
        barriers: [String] = [],
        adjustedStrategy: String? = nil,
        keyInsight: String? = nil,
        commitmentActions: [String] = [],
        paceAtCheckIn: GoalPace,
        progressAtCheckIn: Double,
        conversationTurnCount: Int = 0
    ) {
        self.id = id
        self.goalID = goalID
        self.goalTypeRawValue = goalType.rawValue
        self.headline = headline
        self.whatsWorkingJSON = Self.encodeJSON(whatsWorking)
        self.whatsNotWorkingJSON = Self.encodeJSON(whatsNotWorking)
        self.barriersJSON = Self.encodeJSON(barriers)
        self.adjustedStrategy = adjustedStrategy
        self.keyInsight = keyInsight
        self.commitmentActionsJSON = Self.encodeJSON(commitmentActions)
        self.paceAtCheckInRawValue = paceAtCheckIn.rawValue
        self.progressAtCheckIn = progressAtCheckIn
        self.conversationTurnCount = conversationTurnCount
        self.createdAt = .now
    }

    // MARK: - JSON Helpers

    private static func decodeJSON(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return decoded
    }

    private static func encodeJSON(_ value: [String]) -> String {
        (try? String(data: JSONEncoder().encode(value), encoding: .utf8)) ?? "[]"
    }
}
