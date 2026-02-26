//
//  SAMModels-Goal.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase X: Goal Setting & Decomposition
//
//  Business goal model with type-safe enums for goal tracking
//  and pacing evaluation against existing SAM data streams.
//

import SwiftData
import Foundation
import SwiftUI

// MARK: - GoalType

/// The kind of business metric a goal tracks.
public enum GoalType: String, Codable, Sendable, CaseIterable {
    case newClients       = "New Clients"
    case policiesSubmitted = "Policies Submitted"
    case productionVolume = "Production Volume"
    case recruiting       = "Recruiting"
    case meetingsHeld     = "Meetings Held"
    case contentPosts     = "Content Posts"
    case deepWorkHours    = "Deep Work Hours"

    public var displayName: String { rawValue }

    public var icon: String {
        switch self {
        case .newClients:        return "person.badge.plus"
        case .policiesSubmitted: return "doc.text.fill"
        case .productionVolume:  return "dollarsign.circle.fill"
        case .recruiting:        return "person.3.fill"
        case .meetingsHeld:      return "calendar"
        case .contentPosts:      return "text.bubble.fill"
        case .deepWorkHours:     return "brain.head.profile"
        }
    }

    public var unit: String {
        switch self {
        case .newClients:        return "clients"
        case .policiesSubmitted: return "policies"
        case .productionVolume:  return "$"
        case .recruiting:        return "recruits"
        case .meetingsHeld:      return "meetings"
        case .contentPosts:      return "posts"
        case .deepWorkHours:     return "hours"
        }
    }

    public var color: Color {
        switch self {
        case .newClients:        return .green
        case .policiesSubmitted: return .blue
        case .productionVolume:  return .purple
        case .recruiting:        return .teal
        case .meetingsHeld:      return .orange
        case .contentPosts:      return .pink
        case .deepWorkHours:     return .indigo
        }
    }

    public var isCurrency: Bool {
        self == .productionVolume
    }
}

// MARK: - GoalPace

/// How a goal is pacing relative to its expected progress.
public enum GoalPace: String, Codable, Sendable {
    case ahead   = "Ahead"
    case onTrack = "On Track"
    case behind  = "Behind"
    case atRisk  = "At Risk"

    public var displayName: String { rawValue }

    public var color: Color {
        switch self {
        case .ahead:   return .green
        case .onTrack: return .blue
        case .behind:  return .orange
        case .atRisk:  return .red
        }
    }

    public var icon: String {
        switch self {
        case .ahead:   return "arrow.up.right.circle.fill"
        case .onTrack: return "checkmark.circle.fill"
        case .behind:  return "exclamationmark.circle.fill"
        case .atRisk:  return "exclamationmark.triangle.fill"
        }
    }
}

// MARK: - BusinessGoal

/// A user-defined business target tracked against existing SAM data streams.
/// Progress is always computed live — no stored currentValue.
@Model
public final class BusinessGoal {
    @Attribute(.unique) public var id: UUID

    /// Raw storage for GoalType enum.
    public var goalTypeRawValue: String

    /// User-editable label (default auto-generated from type + target).
    public var title: String

    /// The numeric target.
    public var targetValue: Double

    /// Period start.
    public var startDate: Date

    /// Period end (deadline).
    public var endDate: Date

    /// Soft archive flag — false hides from active views.
    public var isActive: Bool

    /// Optional user notes.
    public var notes: String?

    public var createdAt: Date
    public var updatedAt: Date

    // MARK: - Transient Typed Accessor

    @Transient
    public var goalType: GoalType {
        get { GoalType(rawValue: goalTypeRawValue) ?? .newClients }
        set { goalTypeRawValue = newValue.rawValue }
    }

    public init(
        id: UUID = UUID(),
        goalType: GoalType,
        title: String,
        targetValue: Double,
        startDate: Date,
        endDate: Date,
        isActive: Bool = true,
        notes: String? = nil
    ) {
        self.id = id
        self.goalTypeRawValue = goalType.rawValue
        self.title = title
        self.targetValue = targetValue
        self.startDate = startDate
        self.endDate = endDate
        self.isActive = isActive
        self.notes = notes
        self.createdAt = .now
        self.updatedAt = .now
    }
}
