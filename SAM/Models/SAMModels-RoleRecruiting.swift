//
//  SAMModels-RoleRecruiting.swift
//  SAM
//
//  Created on March 17, 2026.
//  Role Recruiting: Discovery & cultivation layer upstream of existing pipelines.
//
//  RoleDefinition — user-defined roles with criteria for AI scoring.
//  RoleCandidate — scored contact linked to a role with stage tracking.
//

import SwiftData
import Foundation
import SwiftUI

// MARK: - RoleCandidateStage

/// Lightweight 5-stage pipeline for role candidate cultivation.
public enum RoleCandidateStage: String, Codable, Sendable, CaseIterable {
    case suggested    = "Suggested"
    case considering  = "Considering"
    case approached   = "Approached"
    case committed    = "Committed"
    case passed       = "Passed"

    /// Sort order (0 = earliest stage).
    public var order: Int {
        switch self {
        case .suggested:   return 0
        case .considering: return 1
        case .approached:  return 2
        case .committed:   return 3
        case .passed:      return 4
        }
    }

    /// Whether this stage is a terminal state.
    public var isTerminal: Bool {
        switch self {
        case .committed, .passed: return true
        default: return false
        }
    }

    /// Display color for the stage.
    public var color: Color {
        switch self {
        case .suggested:   return .gray
        case .considering: return .blue
        case .approached:  return .orange
        case .committed:   return .green
        case .passed:      return .red
        }
    }

    /// SF Symbol icon for the stage.
    public var icon: String {
        switch self {
        case .suggested:   return "lightbulb"
        case .considering: return "eye"
        case .approached:  return "paperplane"
        case .committed:   return "checkmark.seal"
        case .passed:      return "xmark.circle"
        }
    }

    /// Next stage in the pipeline, or nil if terminal.
    public var next: RoleCandidateStage? {
        switch self {
        case .suggested:   return .considering
        case .considering: return .approached
        case .approached:  return .committed
        case .committed:   return nil
        case .passed:      return nil
        }
    }
}

// MARK: - RoleDefinition

/// A user-defined role with criteria for AI-powered candidate discovery.
@Model
public final class RoleDefinition {
    @Attribute(.unique) public var id: UUID

    /// Display name: "ABT Board Member", "Referral Partner", "WFG Agent"
    public var name: String

    /// What the person will do in this role.
    public var roleDescription: String

    /// Free-text of who's a good fit.
    public var idealCandidateProfile: String

    /// Structured bullet list for scoring — stored as JSON.
    public var criteriaJSON: String

    /// Accumulated rejection reasons fed back into scoring prompts — stored as JSON.
    public var refinementNotesJSON: String

    /// Disqualifying conditions — stored as JSON. E.g. "Employees of ABT", "Anyone compensated by the organization".
    public var exclusionCriteriaJSON: String = "[]"

    /// Optional time commitment description.
    public var timeCommitment: String?

    /// How many people needed for this role.
    public var targetCount: Int

    /// Whether this role is actively being recruited for.
    public var isActive: Bool

    // MARK: - Content Generation

    /// Whether SAM should generate social media topic suggestions related to this role.
    public var contentGenerationEnabled: Bool = false

    /// Why the world should know about this group — injected into content advisor prompts.
    /// E.g., "This group oversees Bible translation for dispersed Aramaic-speaking peoples
    /// whose language and cultural heritage spans millennia."
    public var contentBrief: String = ""

    /// Hex color (e.g., "#34C759") assigned to this role for badges and card borders.
    /// nil = fall back to RoleBadgeStyle default for known names, gray otherwise.
    public var colorHex: String?

    public var createdAt: Date
    public var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \RoleCandidate.roleDefinition)
    public var candidates: [RoleCandidate] = []

    // MARK: - Transient Helpers

    @Transient
    public var criteria: [String] {
        get {
            guard let data = criteriaJSON.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let json = String(data: data, encoding: .utf8) {
                criteriaJSON = json
            }
        }
    }

    @Transient
    public var refinementNotes: [String] {
        get {
            guard let data = refinementNotesJSON.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let json = String(data: data, encoding: .utf8) {
                refinementNotesJSON = json
            }
        }
    }

    @Transient
    public var exclusionCriteria: [String] {
        get {
            guard let data = exclusionCriteriaJSON.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let json = String(data: data, encoding: .utf8) {
                exclusionCriteriaJSON = json
            }
        }
    }

    @Transient
    public var filledCount: Int {
        candidates.filter { $0.stage == .committed }.count
    }

    @Transient
    public var activeCount: Int {
        candidates.filter { !$0.stage.isTerminal }.count
    }

    public init(
        id: UUID = UUID(),
        name: String,
        roleDescription: String = "",
        idealCandidateProfile: String = "",
        criteria: [String] = [],
        refinementNotes: [String] = [],
        exclusionCriteria: [String] = [],
        timeCommitment: String? = nil,
        targetCount: Int = 1,
        isActive: Bool = true,
        contentGenerationEnabled: Bool = false,
        contentBrief: String = "",
        colorHex: String? = nil
    ) {
        self.id = id
        self.name = name
        self.roleDescription = roleDescription
        self.idealCandidateProfile = idealCandidateProfile
        self.criteriaJSON = (try? String(data: JSONEncoder().encode(criteria), encoding: .utf8)) ?? "[]"
        self.refinementNotesJSON = (try? String(data: JSONEncoder().encode(refinementNotes), encoding: .utf8)) ?? "[]"
        self.exclusionCriteriaJSON = (try? String(data: JSONEncoder().encode(exclusionCriteria), encoding: .utf8)) ?? "[]"
        self.timeCommitment = timeCommitment
        self.targetCount = targetCount
        self.isActive = isActive
        self.contentGenerationEnabled = contentGenerationEnabled
        self.contentBrief = contentBrief
        self.colorHex = colorHex
        self.createdAt = .now
        self.updatedAt = .now
    }
}

// MARK: - RoleCandidate

/// A person scored as a potential candidate for a role.
@Model
public final class RoleCandidate {
    @Attribute(.unique) public var id: UUID

    @Relationship(deleteRule: .nullify)
    public var person: SamPerson?

    @Relationship(deleteRule: .nullify)
    public var roleDefinition: RoleDefinition?

    /// Raw storage for RoleCandidateStage enum.
    public var stageRawValue: String

    /// AI-computed match score (0.0–1.0).
    public var matchScore: Double

    /// LLM-generated rationale, 2–3 sentences.
    public var matchRationale: String

    /// Strength signals — stored as JSON.
    public var strengthSignalsJSON: String

    /// Gap signals — stored as JSON.
    public var gapSignalsJSON: String

    /// User notes about this candidate.
    public var userNotes: String?

    /// When the AI identified this candidate.
    public var identifiedAt: Date

    /// When the candidate entered their current stage.
    public var stageEnteredAt: Date

    /// Last time user contacted this candidate about the role.
    public var lastContactedAt: Date?

    /// false = AI-surfaced but not yet reviewed by user.
    public var isUserApproved: Bool

    // MARK: - Transient Accessors

    @Transient
    public var stage: RoleCandidateStage {
        get { RoleCandidateStage(rawValue: stageRawValue) ?? .suggested }
        set { stageRawValue = newValue.rawValue }
    }

    @Transient
    public var strengthSignals: [String] {
        get {
            guard let data = strengthSignalsJSON.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let json = String(data: data, encoding: .utf8) {
                strengthSignalsJSON = json
            }
        }
    }

    @Transient
    public var gapSignals: [String] {
        get {
            guard let data = gapSignalsJSON.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let json = String(data: data, encoding: .utf8) {
                gapSignalsJSON = json
            }
        }
    }

    public init(
        id: UUID = UUID(),
        person: SamPerson? = nil,
        roleDefinition: RoleDefinition? = nil,
        stage: RoleCandidateStage = .suggested,
        matchScore: Double = 0,
        matchRationale: String = "",
        strengthSignals: [String] = [],
        gapSignals: [String] = [],
        userNotes: String? = nil,
        identifiedAt: Date = .now,
        stageEnteredAt: Date = .now,
        lastContactedAt: Date? = nil,
        isUserApproved: Bool = false
    ) {
        self.id = id
        self.person = person
        self.roleDefinition = roleDefinition
        self.stageRawValue = stage.rawValue
        self.matchScore = matchScore
        self.matchRationale = matchRationale
        self.strengthSignalsJSON = (try? String(data: JSONEncoder().encode(strengthSignals), encoding: .utf8)) ?? "[]"
        self.gapSignalsJSON = (try? String(data: JSONEncoder().encode(gapSignals), encoding: .utf8)) ?? "[]"
        self.userNotes = userNotes
        self.identifiedAt = identifiedAt
        self.stageEnteredAt = stageEnteredAt
        self.lastContactedAt = lastContactedAt
        self.isUserApproved = isUserApproved
    }
}
