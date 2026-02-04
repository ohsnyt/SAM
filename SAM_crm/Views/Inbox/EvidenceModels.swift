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
    case unlinkedEvidence
    case divorce
    case comingOfAge
    case partnerLeft
    case productOpportunity
    case complianceRisk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unlinkedEvidence: return "Unlinked Evidence"
        case .divorce: return "Divorce / Separation"
        case .comingOfAge: return "Coming of Age"
        case .partnerLeft: return "Partner Left"
        case .productOpportunity: return "Product Opportunity"
        case .complianceRisk: return "Compliance Risk"
        }
    }

    var systemImage: String {
        switch self {
        case .unlinkedEvidence: return "link.badge.plus"
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

    var status: LinkSuggestionStatus = .pending
    var decidedAt: Date? = nil
}

enum EvidenceTriageState: String, Codable, Hashable {
    case needsReview
    case done
}

/// A single resolved participant extracted from an event or message.
/// `isOrganizer` is true for the event host / message sender so the UI can
/// differentiate them from other invitees.
struct ParticipantHint: Identifiable, Hashable, Codable {
    /// Stable identity: use the display string itself so ForEach works
    /// without an extra stored ID.
    var id: String { displayName }

    /// Human-readable label: "Full Name <email>", a bare email, or a
    /// fallback like "Unknown Participant".
    let displayName: String

    /// True when this participant is the organiser / host of the event.
    let isOrganizer: Bool

    /// True when the participant was successfully matched to a CNContact.
    /// False for bare-email or placeholder fall-backs.
    let isVerified: Bool

    /// The raw email address extracted from the mailto: URL, when available.
    /// Used by the UI to deep-link into Contacts.app for unverified participants.
    let rawEmail: String?
}

struct EvidenceItem: Identifiable, Hashable, Codable {
    let id: UUID
    var state: EvidenceTriageState

    /// Stable identity for upsert (e.g. eventkit:<calendarItemIdentifier>)
    var sourceUID: String = ""

    let source: EvidenceSource
    var occurredAt: Date
    var title: String
    var snippet: String

    // Optional long text (email body, transcript, note body)
    var bodyText: String?

    // Resolved participant hints (name + organiser flag)
    var participantHints: [ParticipantHint]

    // What the system thinks this might imply
    var signals: [EvidenceSignal]

    // Proposed links (user must confirm)
    var proposedLinks: [ProposedLink]

    // Confirmed links (user action)
    var linkedPeople: [UUID]
    var linkedContexts: [UUID]
}

enum LinkSuggestionStatus: String, Codable, Hashable, CaseIterable, Identifiable {
    case pending
    case accepted
    case declined

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pending: return "Pending"
        case .accepted: return "Accepted"
        case .declined: return "Declined"
        }
    }
}
