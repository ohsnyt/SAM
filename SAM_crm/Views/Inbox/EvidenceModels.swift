//
//  EvidenceModels.swift
//  SAM_crm
//
//  Inbox evidence pipeline models (mock-first).
//

import Foundation

enum EvidenceSource: String, Codable, Hashable, CaseIterable, Identifiable {
    case mail
    case calendar
    case zoom
    case note
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mail: return "Mail"
        case .calendar: return "Calendar"
        case .zoom: return "Zoom"
        case .note: return "Notes"
        case .manual: return "Manual"
        }
    }

    var systemImage: String {
        switch self {
        case .mail: return "envelope"
        case .calendar: return "calendar"
        case .zoom: return "video"
        case .note: return "note.text"
        case .manual: return "square.and.pencil"
        }
    }
}

enum EvidenceSignalKind: String, Codable, Hashable, CaseIterable, Identifiable {
    case divorce
    case comingOfAge
    case partnerLeft
    case productOpportunity
    case complianceRisk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .divorce: return "Divorce / Separation"
        case .comingOfAge: return "Coming of Age"
        case .partnerLeft: return "Partner Left"
        case .productOpportunity: return "Product Opportunity"
        case .complianceRisk: return "Compliance Risk"
        }
    }

    var systemImage: String {
        switch self {
        case .divorce: return "heart.slash"
        case .comingOfAge: return "birthday.cake"
        case .partnerLeft: return "person.badge.minus"
        case .productOpportunity: return "lightbulb"
        case .complianceRisk: return "exclamationmark.shield"
        }
    }
}

struct EvidenceSignal: Identifiable, Hashable, Codable {
    let id: UUID
    let kind: EvidenceSignalKind
    let confidence: Double
    let reason: String
}

enum EvidenceLinkTarget: String, Codable, Hashable {
    case person
    case context
}

struct ProposedLink: Identifiable, Hashable, Codable {
    let id: UUID
    let target: EvidenceLinkTarget
    let targetID: UUID
    let displayName: String
    let secondaryLine: String?
    let confidence: Double
    let reason: String
}

enum EvidenceTriageState: String, Codable, Hashable {
    case needsReview
    case done
}

struct EvidenceItem: Identifiable, Hashable, Codable {
    let id: UUID
    var state: EvidenceTriageState

    let source: EvidenceSource
    let occurredAt: Date
    let title: String
    let snippet: String

    // Optional long text (email body, transcript, note body)
    var bodyText: String?

    // Lightweight extracted hints (e.g., emails/phones)
    var participantHints: [String]

    // What the system thinks this might imply
    var signals: [EvidenceSignal]

    // Proposed links (user must confirm)
    var proposedLinks: [ProposedLink]

    // Confirmed links (user action)
    var linkedPeople: [UUID]
    var linkedContexts: [UUID]
}
