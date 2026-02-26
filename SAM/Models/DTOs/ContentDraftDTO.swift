//
//  ContentDraftDTO.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase W: Content Assist & Social Media Coaching
//
//  DTO for AI-generated content drafts with compliance flags.
//

import Foundation

// MARK: - Public DTO

/// A generated content draft with optional compliance warnings.
nonisolated public struct ContentDraft: Codable, Sendable {
    public let draftText: String
    public let complianceFlags: [String]

    public init(draftText: String, complianceFlags: [String] = []) {
        self.draftText = draftText
        self.complianceFlags = complianceFlags
    }
}

// MARK: - LLM Response Type (for JSON parsing)

nonisolated struct LLMContentDraft: Codable, Sendable {
    let draftText: String?
    let complianceFlags: [String]?

    enum CodingKeys: String, CodingKey {
        case draftText = "draft_text"
        case complianceFlags = "compliance_flags"
    }
}
