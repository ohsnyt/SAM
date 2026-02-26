//
//  SAMModels-TimeEntry.swift
//  SAM
//
//  Created on February 25, 2026.
//  Phase Q: Time Tracking & Categorization
//
//  Separate model for time tracking — supports both auto-categorized calendar
//  events and manual time entries for non-calendar activities.
//

import SwiftData
import Foundation
import SwiftUI

// MARK: - TimeCategory

/// WFG-specific time categories for classifying how time is spent.
public enum TimeCategory: String, Codable, Sendable, CaseIterable {
    case prospecting       = "Prospecting"
    case clientMeeting     = "Client Meeting"
    case policyReview      = "Policy Review"
    case recruiting        = "Recruiting"
    case trainingMentoring = "Training/Mentoring"
    case admin             = "Admin"
    case deepWork          = "Deep Work"
    case personalDev       = "Personal Development"
    case travel            = "Travel"
    case other             = "Other"

    /// Display color for charts and badges.
    public var color: Color {
        switch self {
        case .prospecting:       return .orange
        case .clientMeeting:     return .green
        case .policyReview:      return .blue
        case .recruiting:        return .teal
        case .trainingMentoring: return .indigo
        case .admin:             return .gray
        case .deepWork:          return .purple
        case .personalDev:       return .cyan
        case .travel:            return .brown
        case .other:             return .secondary
        }
    }

    /// SF Symbol icon for the category.
    public var icon: String {
        switch self {
        case .prospecting:       return "megaphone"
        case .clientMeeting:     return "person.2"
        case .policyReview:      return "doc.text.magnifyingglass"
        case .recruiting:        return "person.badge.plus"
        case .trainingMentoring: return "graduationcap"
        case .admin:             return "tray.full"
        case .deepWork:          return "brain.head.profile"
        case .personalDev:       return "book"
        case .travel:            return "car"
        case .other:             return "questionmark.circle"
        }
    }
}

// MARK: - TimeEntry

/// A single block of tracked time, either auto-generated from a calendar event
/// or manually created by the user.
///
/// Uses UUID references (`sourceEvidenceID`, `linkedPeopleIDs`) instead of
/// `@Relationship` to avoid requiring inverses on existing models.
@Model
public final class TimeEntry {
    @Attribute(.unique) public var id: UUID

    /// Raw storage for TimeCategory enum.
    public var categoryRawValue: String

    /// Typed category accessor.
    @Transient
    public var category: TimeCategory {
        get { TimeCategory(rawValue: categoryRawValue) ?? .other }
        set { categoryRawValue = newValue.rawValue }
    }

    /// Event title or manual label.
    public var title: String

    /// Duration in minutes — used for aggregation.
    public var durationMinutes: Int

    /// When this time block started.
    public var startedAt: Date

    /// When this time block ended.
    public var endedAt: Date

    /// True when the user changed the auto-assigned category.
    public var isManualOverride: Bool = false

    /// True when this entry was manually created (no linked calendar event).
    public var isManualEntry: Bool = false

    /// Calendar event ID (nil for manual entries).
    public var sourceEvidenceID: UUID?

    /// People associated with this time block.
    public var linkedPeopleIDs: [UUID] = []

    /// When this record was created.
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        category: TimeCategory,
        title: String,
        durationMinutes: Int,
        startedAt: Date,
        endedAt: Date,
        isManualOverride: Bool = false,
        isManualEntry: Bool = false,
        sourceEvidenceID: UUID? = nil,
        linkedPeopleIDs: [UUID] = [],
        createdAt: Date = .now
    ) {
        self.id = id
        self.categoryRawValue = category.rawValue
        self.title = title
        self.durationMinutes = durationMinutes
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.isManualOverride = isManualOverride
        self.isManualEntry = isManualEntry
        self.sourceEvidenceID = sourceEvidenceID
        self.linkedPeopleIDs = linkedPeopleIDs
        self.createdAt = createdAt
    }
}
