//
//  SAMModels-Strategic.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase V: Business Intelligence — Strategic Coordinator
//
//  SwiftData model for persisted strategic digests.
//

import Foundation
import SwiftData

// MARK: - StrategicDigest (@Model)

@Model
public final class StrategicDigest {

    @Attribute(.unique) public var id: UUID

    /// When the digest was generated
    public var generatedAt: Date

    /// "morning", "evening", "weekly", "onDemand"
    public var digestTypeRawValue: String

    /// Pipeline health narrative from PipelineAnalyst
    public var pipelineSummary: String

    /// Time allocation narrative from TimeAnalyst
    public var timeSummary: String

    /// Cross-relationship pattern insights from PatternDetector
    public var patternInsights: String

    /// Educational content suggestions from ContentAdvisor
    public var contentSuggestions: String

    /// Top synthesized recommendations (JSON array of StrategicRec)
    public var strategicActions: String

    /// Full structured output for dashboard rendering
    public var rawJSON: String?

    /// Per-recommendation acted/dismissed/ignored tracking (JSON)
    public var feedbackJSON: String?

    /// Pre-computed event topic suggestions (JSON array of SuggestedEventTopic)
    public var eventTopicSuggestions: String?

    /// Sphere this digest is scoped to. `nil` = global / all-Spheres digest
    /// (legacy behavior, what single-Sphere users always see). Set when the
    /// per-Sphere fan-out generates one digest per active Sphere so the
    /// strategic view can show Sphere-specific insight alongside the global
    /// roll-up. Phase 6c of the relationship-model refactor.
    public var sphereID: UUID?

    /// Pre-computed list of people who appear in 2+ active Spheres (JSON
    /// array of CrossSphereInsight). Populated only on the global digest
    /// when the user has 2+ Spheres; nil/empty otherwise. Phase 6d.
    public var crossSphereInsightsJSON: String?

    // MARK: - Transient

    @Transient
    public var digestType: DigestType {
        get { DigestType(rawValue: digestTypeRawValue) ?? .onDemand }
        set { digestTypeRawValue = newValue.rawValue }
    }

    // MARK: - Init

    public init(
        digestType: DigestType,
        pipelineSummary: String = "",
        timeSummary: String = "",
        patternInsights: String = "",
        contentSuggestions: String = "",
        strategicActions: String = "[]",
        sphereID: UUID? = nil
    ) {
        self.id = UUID()
        self.generatedAt = .now
        self.digestTypeRawValue = digestType.rawValue
        self.pipelineSummary = pipelineSummary
        self.timeSummary = timeSummary
        self.patternInsights = patternInsights
        self.contentSuggestions = contentSuggestions
        self.strategicActions = strategicActions
        self.rawJSON = nil
        self.feedbackJSON = nil
        self.sphereID = sphereID
    }
}

// MARK: - DigestType

public enum DigestType: String, Codable, Sendable {
    case morning
    case evening
    case weekly
    case onDemand
}

// MARK: - CrossSphereInsight

/// A person who participates in 2+ active Spheres. Surfaced in the global
/// digest so the user sees where their relationships span roles — useful
/// for context-switching, sensitive intros, and avoiding cross-Sphere
/// double-asks. Phase 6d of the relationship-model refactor.
public struct CrossSphereInsight: Codable, Sendable, Identifiable {
    public var id: UUID
    public var personID: UUID
    public var personName: String
    public var sphereNames: [String]
    public var implication: String

    public init(
        id: UUID = UUID(),
        personID: UUID,
        personName: String,
        sphereNames: [String],
        implication: String
    ) {
        self.id = id
        self.personID = personID
        self.personName = personName
        self.sphereNames = sphereNames
        self.implication = implication
    }
}
