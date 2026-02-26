//
//  SAMModels-Pipeline.swift
//  SAM
//
//  Created on February 25, 2026.
//  Phase R: Pipeline Intelligence
//
//  Immutable audit log of role badge changes (StageTransition) and
//  recruiting pipeline state (RecruitingStage).
//

import SwiftData
import Foundation
import SwiftUI

// MARK: - PipelineType

/// Which pipeline a stage transition belongs to.
public enum PipelineType: String, Codable, Sendable {
    case client    = "client"
    case recruiting = "recruiting"
}

// MARK: - RecruitingStageKind

/// The 7 WFG recruiting stages from initial prospect to producing agent.
public enum RecruitingStageKind: String, Codable, Sendable, CaseIterable {
    case prospect   = "Prospect"
    case presented  = "Presented"
    case signedUp   = "Signed Up"
    case studying   = "Studying"
    case licensed   = "Licensed"
    case firstSale  = "First Sale"
    case producing  = "Producing"

    /// Sort order (0 = earliest stage).
    public var order: Int {
        switch self {
        case .prospect:  return 0
        case .presented: return 1
        case .signedUp:  return 2
        case .studying:  return 3
        case .licensed:  return 4
        case .firstSale: return 5
        case .producing: return 6
        }
    }

    /// Display color for the stage.
    public var color: Color {
        switch self {
        case .prospect:  return .gray
        case .presented: return .mint
        case .signedUp:  return .blue
        case .studying:  return .indigo
        case .licensed:  return .purple
        case .firstSale: return .orange
        case .producing: return .green
        }
    }

    /// SF Symbol icon for the stage.
    public var icon: String {
        switch self {
        case .prospect:  return "person.badge.plus"
        case .presented: return "person.bubble"
        case .signedUp:  return "signature"
        case .studying:  return "book"
        case .licensed:  return "checkmark.seal"
        case .firstSale: return "dollarsign.circle"
        case .producing: return "chart.line.uptrend.xyaxis"
        }
    }

    /// Next stage in the pipeline, or nil if already at the end.
    public var next: RecruitingStageKind? {
        let all = Self.allCases
        guard let idx = all.firstIndex(of: self), idx + 1 < all.count else { return nil }
        return all[idx + 1]
    }
}

// MARK: - StageTransition

/// Immutable audit log entry for every role badge change.
/// Person relationship uses nullify so historical metrics survive deletion.
@Model
public final class StageTransition {
    @Attribute(.unique) public var id: UUID

    /// The person whose stage changed. Nil if person was deleted (preserves metrics).
    @Relationship(deleteRule: .nullify)
    public var person: SamPerson?

    /// Previous stage ("" for initial entry into the pipeline).
    public var fromStage: String

    /// New stage the person moved to.
    public var toStage: String

    /// When this transition occurred.
    public var transitionDate: Date

    /// Raw storage for PipelineType enum.
    public var pipelineTypeRawValue: String

    /// Optional notes about this transition.
    public var notes: String?

    /// Typed pipeline type accessor.
    @Transient
    public var pipelineType: PipelineType {
        get { PipelineType(rawValue: pipelineTypeRawValue) ?? .client }
        set { pipelineTypeRawValue = newValue.rawValue }
    }

    public init(
        id: UUID = UUID(),
        person: SamPerson?,
        fromStage: String,
        toStage: String,
        transitionDate: Date = .now,
        pipelineType: PipelineType,
        notes: String? = nil
    ) {
        self.id = id
        self.person = person
        self.fromStage = fromStage
        self.toStage = toStage
        self.transitionDate = transitionDate
        self.pipelineTypeRawValue = pipelineType.rawValue
        self.notes = notes
    }
}

// MARK: - RecruitingStage

/// Current recruiting pipeline state for a person with the "Agent" badge.
/// Repository enforces one RecruitingStage per person.
@Model
public final class RecruitingStage {
    @Attribute(.unique) public var id: UUID

    /// The person being recruited. Nil if person was deleted.
    @Relationship(deleteRule: .nullify)
    public var person: SamPerson?

    /// Raw storage for RecruitingStageKind enum.
    public var stageRawValue: String

    /// When this person entered their current stage.
    public var enteredDate: Date

    /// Last mentoring contact date (for cadence tracking).
    public var mentoringLastContact: Date?

    /// Optional notes about this recruit's progress.
    public var notes: String?

    /// Typed stage accessor.
    @Transient
    public var stage: RecruitingStageKind {
        get { RecruitingStageKind(rawValue: stageRawValue) ?? .prospect }
        set { stageRawValue = newValue.rawValue }
    }

    public init(
        id: UUID = UUID(),
        person: SamPerson?,
        stage: RecruitingStageKind,
        enteredDate: Date = .now,
        mentoringLastContact: Date? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.person = person
        self.stageRawValue = stage.rawValue
        self.enteredDate = enteredDate
        self.mentoringLastContact = mentoringLastContact
        self.notes = notes
    }
}
