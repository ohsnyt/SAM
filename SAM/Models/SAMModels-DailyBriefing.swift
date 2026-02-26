//
//  SAMModels-DailyBriefing.swift
//  SAM
//
//  Created by Assistant on 2/24/26.
//  Daily Briefing System
//
//  SwiftData model for persisted daily briefings (morning + evening).
//  Structured sections stored as Codable arrays for recap aggregation.
//

import Foundation
import SwiftData

// ─────────────────────────────────────────────────────────────────────
// MARK: - SamDailyBriefing (@Model)
// ─────────────────────────────────────────────────────────────────────

@Model
public final class SamDailyBriefing {

    @Attribute(.unique) public var id: UUID

    /// "morning" or "evening"
    public var briefingTypeRawValue: String
    /// Start of day — used as key for deduplication
    public var dateKey: Date
    /// When the briefing was generated
    public var generatedAt: Date
    /// Whether the user has viewed this briefing
    public var wasViewed: Bool
    /// When the user first viewed it
    public var viewedAt: Date?

    // MARK: - Structured Sections (Codable arrays)

    public var calendarItems: [BriefingCalendarItem]
    public var priorityActions: [BriefingAction]
    public var followUps: [BriefingFollowUp]
    public var lifeEventOutreach: [BriefingLifeEvent]
    public var tomorrowPreview: [BriefingCalendarItem]
    /// Evening only
    public var accomplishments: [BriefingAccomplishment]
    public var streakUpdates: [BriefingStreakUpdate]
    /// Monday morning only — top priorities for the week
    public var weeklyPriorities: [BriefingAction]
    /// Top strategic recommendations for today (Phase V)
    public var strategicHighlights: [BriefingAction]

    // MARK: - Raw Metrics (for recap aggregation)

    public var meetingCount: Int
    public var notesTakenCount: Int
    public var outcomesCompletedCount: Int
    public var outcomesDismissedCount: Int
    public var followUpsCompletedCount: Int
    public var newContactsCount: Int
    public var emailsProcessedCount: Int

    // MARK: - Narratives

    /// Rich prose for visual display
    public var narrativeSummary: String?
    /// Shorter, conversational prose for future TTS
    public var ttsNarrative: String?

    // MARK: - Transient

    @Transient
    public var briefingType: BriefingType {
        get { BriefingType(rawValue: briefingTypeRawValue) ?? .morning }
        set { briefingTypeRawValue = newValue.rawValue }
    }

    // MARK: - Init

    public init(
        briefingType: BriefingType,
        dateKey: Date,
        calendarItems: [BriefingCalendarItem] = [],
        priorityActions: [BriefingAction] = [],
        followUps: [BriefingFollowUp] = [],
        lifeEventOutreach: [BriefingLifeEvent] = [],
        tomorrowPreview: [BriefingCalendarItem] = [],
        accomplishments: [BriefingAccomplishment] = [],
        streakUpdates: [BriefingStreakUpdate] = [],
        weeklyPriorities: [BriefingAction] = [],
        strategicHighlights: [BriefingAction] = []
    ) {
        self.id = UUID()
        self.briefingTypeRawValue = briefingType.rawValue
        self.dateKey = dateKey
        self.generatedAt = .now
        self.wasViewed = false
        self.viewedAt = nil
        self.calendarItems = calendarItems
        self.priorityActions = priorityActions
        self.followUps = followUps
        self.lifeEventOutreach = lifeEventOutreach
        self.tomorrowPreview = tomorrowPreview
        self.accomplishments = accomplishments
        self.streakUpdates = streakUpdates
        self.weeklyPriorities = weeklyPriorities
        self.strategicHighlights = strategicHighlights
        self.meetingCount = 0
        self.notesTakenCount = 0
        self.outcomesCompletedCount = 0
        self.outcomesDismissedCount = 0
        self.followUpsCompletedCount = 0
        self.newContactsCount = 0
        self.emailsProcessedCount = 0
        self.narrativeSummary = nil
        self.ttsNarrative = nil
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - BriefingType
// ─────────────────────────────────────────────────────────────────────

public enum BriefingType: String, Codable, Sendable {
    case morning
    case evening
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Codable Value Types
// ─────────────────────────────────────────────────────────────────────

public struct BriefingCalendarItem: Codable, Sendable, Identifiable {
    public var id: UUID
    public var eventTitle: String
    public var startsAt: Date
    public var endsAt: Date?
    public var attendeeNames: [String]
    public var attendeeRoles: [String]
    public var preparationNote: String?
    public var healthStatus: String?   // "healthy", "at_risk", "cold"

    public init(
        id: UUID = UUID(),
        eventTitle: String,
        startsAt: Date,
        endsAt: Date? = nil,
        attendeeNames: [String] = [],
        attendeeRoles: [String] = [],
        preparationNote: String? = nil,
        healthStatus: String? = nil
    ) {
        self.id = id
        self.eventTitle = eventTitle
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.attendeeNames = attendeeNames
        self.attendeeRoles = attendeeRoles
        self.preparationNote = preparationNote
        self.healthStatus = healthStatus
    }
}

public struct BriefingAction: Codable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var rationale: String?
    public var personName: String?
    public var personID: UUID?
    public var urgency: String          // "immediate", "soon", "standard", "low"
    public var sourceKind: String       // "outcome", "action_item", "relationship_health"

    public init(
        id: UUID = UUID(),
        title: String,
        rationale: String? = nil,
        personName: String? = nil,
        personID: UUID? = nil,
        urgency: String = "standard",
        sourceKind: String = "outcome"
    ) {
        self.id = id
        self.title = title
        self.rationale = rationale
        self.personName = personName
        self.personID = personID
        self.urgency = urgency
        self.sourceKind = sourceKind
    }
}

public struct BriefingFollowUp: Codable, Sendable, Identifiable {
    public var id: UUID
    public var personName: String
    public var personID: UUID?
    public var reason: String
    public var daysSinceInteraction: Int
    public var suggestedAction: String?

    public init(
        id: UUID = UUID(),
        personName: String,
        personID: UUID? = nil,
        reason: String,
        daysSinceInteraction: Int = 0,
        suggestedAction: String? = nil
    ) {
        self.id = id
        self.personName = personName
        self.personID = personID
        self.reason = reason
        self.daysSinceInteraction = daysSinceInteraction
        self.suggestedAction = suggestedAction
    }
}

public struct BriefingLifeEvent: Codable, Sendable, Identifiable {
    public var id: UUID
    public var personName: String
    public var personID: UUID?
    public var eventType: String
    public var eventDescription: String
    public var outreachSuggestion: String?

    public init(
        id: UUID = UUID(),
        personName: String,
        personID: UUID? = nil,
        eventType: String,
        eventDescription: String,
        outreachSuggestion: String? = nil
    ) {
        self.id = id
        self.personName = personName
        self.personID = personID
        self.eventType = eventType
        self.eventDescription = eventDescription
        self.outreachSuggestion = outreachSuggestion
    }
}

public struct BriefingAccomplishment: Codable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var category: String         // "outcome", "note", "meeting", "contact"
    public var personName: String?

    public init(
        id: UUID = UUID(),
        title: String,
        category: String = "outcome",
        personName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.personName = personName
    }
}

public struct BriefingStreakUpdate: Codable, Sendable, Identifiable {
    public var id: UUID
    public var streakName: String
    public var currentCount: Int
    public var isNewRecord: Bool
    public var message: String

    public init(
        id: UUID = UUID(),
        streakName: String,
        currentCount: Int,
        isNewRecord: Bool = false,
        message: String
    ) {
        self.id = id
        self.streakName = streakName
        self.currentCount = currentCount
        self.isNewRecord = isNewRecord
        self.message = message
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - BriefingMetrics (Sendable, for cross-actor boundary)
// ─────────────────────────────────────────────────────────────────────

/// Lightweight metrics snapshot passed to AI narrative service.
/// Not persisted — computed at generation time from the briefing model.
public struct BriefingMetrics: Sendable {
    public var meetingCount: Int
    public var notesTakenCount: Int
    public var outcomesCompletedCount: Int
    public var outcomesDismissedCount: Int
    public var followUpsCompletedCount: Int
    public var newContactsCount: Int
    public var emailsProcessedCount: Int

    public init(
        meetingCount: Int = 0,
        notesTakenCount: Int = 0,
        outcomesCompletedCount: Int = 0,
        outcomesDismissedCount: Int = 0,
        followUpsCompletedCount: Int = 0,
        newContactsCount: Int = 0,
        emailsProcessedCount: Int = 0
    ) {
        self.meetingCount = meetingCount
        self.notesTakenCount = notesTakenCount
        self.outcomesCompletedCount = outcomesCompletedCount
        self.outcomesDismissedCount = outcomesDismissedCount
        self.followUpsCompletedCount = followUpsCompletedCount
        self.newContactsCount = newContactsCount
        self.emailsProcessedCount = emailsProcessedCount
    }
}
