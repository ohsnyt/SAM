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
        strategicActions: String = "[]"
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
    }
}

// MARK: - DigestType

public enum DigestType: String, Codable, Sendable {
    case morning
    case evening
    case weekly
    case onDemand
}
