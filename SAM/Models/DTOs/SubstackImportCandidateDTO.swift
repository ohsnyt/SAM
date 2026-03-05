//
//  SubstackImportCandidateDTO.swift
//  SAM
//
//  DTOs for Substack subscriber matching during import.
//  Simpler than LinkedIn/Facebook — subscriber matching is email-only.
//

import Foundation

/// A subscriber candidate with match status after email comparison.
struct SubstackSubscriberCandidate: Sendable, Identifiable {
    let id: UUID
    let email: String
    let subscribedAt: Date
    let planType: String          // "free" | "paid"
    let isActive: Bool
    let matchStatus: SubstackMatchStatus
    var classification: SubstackClassification
    let matchedPersonInfo: MatchedPersonInfo?
}

/// Whether the subscriber matched an existing SamPerson.
enum SubstackMatchStatus: Sendable {
    case exactMatchEmail(personID: UUID)
    case noMatch
}

/// How to handle an unmatched subscriber.
enum SubstackClassification: String, Sendable {
    case add    // create as lead
    case later  // triage later
    case skip   // ignore
}

// Note: Reuses MatchedPersonInfo from LinkedInImportCandidateDTO.swift
