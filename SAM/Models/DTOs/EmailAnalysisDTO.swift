//
//  EmailAnalysisDTO.swift
//  SAM_crm
//
//  Created by Assistant on 2/13/26.
//  Email Integration - LLM Analysis Results
//
//  Sendable results from on-device LLM analysis of email content.
//

import Foundation

/// Sendable results from on-device LLM analysis of an email body.
/// Crosses actor boundary from EmailAnalysisService → MailImportCoordinator.
struct EmailAnalysisDTO: Sendable {
    let summary: String                  // 1-2 sentence summary
    let namedEntities: [EmailEntityDTO]  // People, orgs, products mentioned
    let topics: [String]                 // Financial topics detected
    let temporalEvents: [TemporalEventDTO]  // Dates/events mentioned
    let sentiment: Sentiment             // Overall tone
    let analysisVersion: Int

    enum Sentiment: String, Sendable {
        case positive, neutral, negative, urgent
    }
}

struct EmailEntityDTO: Sendable, Identifiable {
    let id: UUID
    let name: String
    let kind: EntityKind
    let confidence: Double

    enum EntityKind: String, Sendable {
        case person
        case organization
        case product
        case financialInstrument
    }
}

struct TemporalEventDTO: Sendable, Identifiable {
    let id: UUID
    let description: String    // "Annual review meeting"
    let dateString: String     // "March 15, 2026" (raw from email)
    let parsedDate: Date?      // Best-effort parsed date
    let confidence: Double
}
