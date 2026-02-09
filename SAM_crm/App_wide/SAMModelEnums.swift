//
//  SAMModelEnums.swift
//  SAM_crm
//
//  All enums and embedded value types used by the @Model classes in
//  SAMModels.swift.  Every type here is Codable so it can be stored
//  inside a SwiftData model as an embedded value *and* round-tripped
//  through BackupPayload JSON.
//
//  Organisation:
//    1. Identity & People
//    2. Context
//    3. Roles & Participation
//    4. Joint Interests
//    5. Consent
//    6. Products & Coverage
//    7. Evidence & Signals
//    8. Insights (embedded, not yet standalone @Model)
//

import Foundation

// ─────────────────────────────────────────────────────────────────────
// MARK: - 1. Identity & People
// ─────────────────────────────────────────────────────────────────────

/// A lightweight, display-only snapshot of a person's membership in
/// a context.  Stored flat on `SamPerson` so that list and search
/// views can render without traversing the full Context graph.
/// Kept in sync with `ContextParticipation` by the store layer.
public struct ContextChip: Identifiable, Codable, Hashable {
    /// Stable id; defaults to a new UUID in code but the synthesised
    /// `Decodable` init restores the original value on round-trip.
    public let id: UUID
    public let name:        String
    public let kindDisplay: String   // e.g. "Household"
    public let icon:        String   // SF Symbol name

    public init(id: UUID = .init(), name: String, kindDisplay: String, icon: String) {
        self.id          = id
        self.name        = name
        self.kindDisplay = kindDisplay
        self.icon        = icon
    }
}

/// A single recent-interaction chip shown on People detail.
/// Will be replaced by a `@Relationship` to a standalone `Interaction`
/// model once interactions are promoted (design doc §12).
public struct InteractionChip: Identifiable, Codable, Hashable {
    public let id:       UUID
    public let title:    String
    public let subtitle: String
    public let whenText: String   // human-friendly relative time ("2d", "1w")
    public let icon:     String   // SF Symbol name

    public init(id: UUID = .init(), title: String, subtitle: String, whenText: String, icon: String) {
        self.id       = id
        self.title    = title
        self.subtitle = subtitle
        self.whenText = whenText
        self.icon     = icon
    }
}

/// An insight card embedded on a Person detail view.
/// Will become a `@Relationship` to a standalone `Insight` model
/// once insights are promoted (design doc §13).
struct PersonInsight: Identifiable, Codable, Hashable {
    let id: UUID

    let kind:              InsightKind
    let message:           String
    let confidence:        Double
    let interactionsCount: Int
    let consentsCount:     Int

    init(
        id: UUID = .init(),
        kind: InsightKind,
        message: String,
        confidence: Double,
        interactionsCount: Int,
        consentsCount: Int
    ) {
        self.id                = id
        self.kind              = kind
        self.message           = message
        self.confidence        = confidence
        self.interactionsCount = interactionsCount
        self.consentsCount     = consentsCount
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 2. Context
// ─────────────────────────────────────────────────────────────────────

/// The classification of a relationship environment.
///
/// **Design-doc note:** the full target vocabulary is in
/// `SAM_Core_Data_Model.md §3` (personalPlanning, agentTeam,
/// agentExternal, referralPartner, vendor).  New cases will be added
/// as the UI grows.
public enum ContextKind: String, Codable, Hashable, CaseIterable {
    case household
    case business
    case recruiting

    public var displayName: String {
        switch self {
        case .household:  return "Household"
        case .business:   return "Business"
        case .recruiting: return "Recruiting"
        }
    }

    public var icon: String {
        switch self {
        case .household:  return "house"
        case .business:   return "building.2"
        case .recruiting: return "person.3"
        }
    }
}

/// A product card shown on a Context detail view.
/// Mirrors `ContextProductModel` from the current struct layer.
public struct ContextProductModel: Identifiable, Codable, Hashable {
    public let id:            UUID
    public let title:         String
    public let subtitle:      String?
    public let statusDisplay: String
    public let icon:          String
    
    public init(id: UUID, title: String, subtitle: String?, statusDisplay: String, icon: String) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.statusDisplay = statusDisplay
        self.icon = icon
    }
}

/// A recent-interaction chip on a Context detail view.
public struct InteractionModel: Identifiable, Codable, Hashable {
    public let id:       UUID
    public let title:    String
    public let subtitle: String
    public let whenText: String
    public let icon:     String
    
    public init(id: UUID, title: String, subtitle: String, whenText: String, icon: String) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.whenText = whenText
        self.icon = icon
    }
}

/// An insight card embedded on a Context detail view.
struct ContextInsight: Identifiable, Codable, Hashable {
    let id: UUID

    let kind:              InsightKind
    let message:           String
    let confidence:        Double
    let interactionsCount: Int
    let consentsCount:     Int

    init(
        id: UUID = .init(),
        kind: InsightKind,
        message: String,
        confidence: Double,
        interactionsCount: Int,
        consentsCount: Int
    ) {
        self.id                = id
        self.kind              = kind
        self.message           = message
        self.confidence        = confidence
        self.interactionsCount = interactionsCount
        self.consentsCount     = consentsCount
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 3. Roles & Participation
// ─────────────────────────────────────────────────────────────────────

/// Typed role vocabulary from the design doc.  Not yet used directly
/// on `ContextParticipation` (which stores `roleBadges: [String]`
/// today) but will become the backing type once the UI supports the
/// full set.
enum RoleType: String, Codable, CaseIterable {
    case insured
    case owner
    case spouse
    case beneficiary
    case jointBeneficiary
    case keyEmployee
    case decisionMaker
    case recruit
    case agentInTraining
    case responsiblePerson
    case dependent
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 4. Joint Interests
// ─────────────────────────────────────────────────────────────────────

public enum JointInterestType: String, Codable, CaseIterable {
    case spousal
    case trustBeneficiaries
    case businessPartners
    case parentChild
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 5. Consent
// ─────────────────────────────────────────────────────────────────────

public enum ConsentStatus: String, Codable, CaseIterable {
    case required
    case satisfied
    case revoked
    case expired

    // ── Display helpers ───────────────────────────────────────────
    public var displayTitle: String {
        switch self {
        case .required:  return "Required"
        case .satisfied: return "Satisfied"
        case .revoked:   return "Revoked"
        case .expired:   return "Expired"
        }
    }

    public var systemImage: String {
        switch self {
        case .required:  return "checkmark.seal"
        case .satisfied: return "checkmark.seal.fill"
        case .revoked:   return "xmark.seal"
        case .expired:   return "clock.badge.exclamationmark"
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 6. Products & Coverage
// ─────────────────────────────────────────────────────────────────────

/// The classification of an insurance or financial product.
public enum ProductType: String, Codable, CaseIterable {
    case lifeInsurance
    case disability
    case buySell
    case keyPerson
    case retirement
    case annuity
    case longTermCare
    case collegeSavings
    case trusts

    public var displayName: String {
        switch self {
        case .lifeInsurance: return "Life Insurance"
        case .disability:    return "Disability"
        case .buySell:       return "Buy-Sell"
        case .keyPerson:     return "Key Person"
        case .retirement:    return "Retirement"
        case .annuity:       return "Annuity"
        case .longTermCare:  return "Long-Term Care"
        case .collegeSavings:return "College Savings"
        case .trusts:        return "Trusts"
        }
    }

    public var defaultIcon: String {
        switch self {
        case .lifeInsurance:  return "shield"
        case .disability:     return "person.badge.shield.checkmark"
        case .buySell:        return "arrow.left.right.circle"
        case .keyPerson:      return "person.crop.circle.badge.checkmark"
        case .retirement:     return "clock.badge.checkmark"
        case .annuity:        return "chart.line.uptrend.xyaxis"
        case .longTermCare:   return "cross.case"
        case .collegeSavings: return "graduationcap"
        case .trusts:         return "building.columns"
        }
    }
}

/// The capacity in which a person is covered by a product.
public enum CoverageRole: String, Codable, CaseIterable {
    case insured
    case beneficiary
    case jointBeneficiary
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 7. Evidence & Signals
// ─────────────────────────────────────────────────────────────────────

/// Where a piece of evidence came from.
public enum EvidenceSource: String, Codable, CaseIterable {
    case calendar
    case mail
    case message
    case note
    case manual

    public var title: String {
        switch self {
        case .calendar: return "Calendar"
        case .mail:     return "Mail"
        case .message:  return "Message"
        case .note:     return "Note"
        case .manual:   return "Manual"
        }
    }

    public var systemImage: String {
        switch self {
        case .calendar: return "calendar"
        case .mail:     return "envelope"
        case .message:  return "message"
        case .note:     return "note.text"
        case .manual:   return "pencil.and.outline"
        }
    }
}

/// Two-state triage for evidence items.
///
/// **Design-doc note:** the target inbox model (§10) envisions
/// `InboxStatus` with new / pinned / snoozed / archived / dismissed.
/// This will replace `EvidenceTriageState` when the UI adds those
/// states.
public enum EvidenceTriageState: String, Codable, CaseIterable {
    case needsReview
    case done
}

/// The typed signal vocabulary produced by `InsightGeneratorV1`.
///
/// **Design-doc note:** the doc (§11) describes signals as
/// `kind: String`.  The typed enum here is strictly more useful —
/// it gives us compile-time exhaustiveness and lets the UI switch on
/// kind for icons/titles.  The raw value is the string that would
/// appear in JSON.
public enum SignalKind: String, Codable, CaseIterable, Sendable {
    case unlinkedEvidence
    case divorce
    case comingOfAge
    case partnerLeft
    case productOpportunity
    case complianceRisk

    var title: String {
        switch self {
        case .unlinkedEvidence:   return "Unlinked Evidence"
        case .divorce:            return "Relationship Change"
        case .comingOfAge:        return "Coming of Age"
        case .partnerLeft:        return "Partner Departure"
        case .productOpportunity: return "Product Opportunity"
        case .complianceRisk:     return "Compliance Risk"
        }
    }

    var systemImage: String {
        switch self {
        case .unlinkedEvidence:   return "link.slash"
        case .divorce:            return "person.2.slash"
        case .comingOfAge:        return "person.badge.plus"
        case .partnerLeft:        return "person.slash"
        case .productOpportunity: return "chart.line.uptrend.xyaxis"
        case .complianceRisk:     return "exclamationmark.shield"
        }
    }
}

/// A single deterministic, explainable tag on an evidence item.
/// Stored as an embedded array inside `EvidenceItem`; recomputed on
/// every upsert by `InsightGeneratorV1`.
public struct EvidenceSignal: Identifiable, Codable, Hashable {
    public let id:         UUID
    public let kind:       SignalKind
    public let confidence: Double   // 0…1
    public let reason:     String   // short, plain-English explanation
    
    public init(id: UUID, kind: SignalKind, confidence: Double, reason: String) {
        self.id = id
        self.kind = kind
        self.confidence = confidence
        self.reason = reason
    }
}

/// Raw attendee info extracted at import time.
public struct ParticipantHint: Identifiable, Codable, Hashable {
    /// Stable id; defaults to a new UUID.
    public let id: UUID

    /// Display name.  "Full Name <email>" when verified; raw email
    /// when not.
    public let displayName: String

    /// Whether this participant is the event organiser.
    public let isOrganizer: Bool

    /// Whether this participant has been matched to a CNContact.
    public let isVerified: Bool

    /// The raw email address extracted from the source, if available.
    public let rawEmail: String?

    public init(
        id: UUID = .init(),
        displayName: String,
        isOrganizer: Bool,
        isVerified: Bool,
        rawEmail: String?
    ) {
        self.id          = id
        self.displayName = displayName
        self.isOrganizer = isOrganizer
        self.isVerified  = isVerified
        self.rawEmail    = rawEmail
    }
}

/// A system-generated suggestion for linking evidence to a person or
/// context.  Carries its own accept/decline lifecycle.
public struct ProposedLink: Identifiable, Codable, Hashable {
    public let id: UUID

    /// What kind of entity is being suggested.
    public let target: EvidenceLinkTarget

    /// The UUID of the suggested entity (person or context).
    public let targetID: UUID

    /// Display name of the suggested entity.
    public let displayName: String

    /// Optional secondary line (e.g. role or context kind).
    public let secondaryLine: String?

    /// How confident the system is in this suggestion (0…1).
    public let confidence: Double

    /// Plain-English explanation of why this link was suggested.
    public let reason: String

    // ── Lifecycle ─────────────────────────────────────────────────
    public var status:     LinkSuggestionStatus = .pending
    public var decidedAt:  Date?                = nil

    public init(
        id: UUID = .init(),
        target: EvidenceLinkTarget,
        targetID: UUID,
        displayName: String,
        secondaryLine: String? = nil,
        confidence: Double,
        reason: String,
        status: LinkSuggestionStatus = .pending,
        decidedAt: Date? = nil
    ) {
        self.id            = id
        self.target        = target
        self.targetID      = targetID
        self.displayName   = displayName
        self.secondaryLine = secondaryLine
        self.confidence    = confidence
        self.reason        = reason
        self.status        = status
        self.decidedAt     = decidedAt
    }
}

/// The kind of entity a proposed link points at.
public enum EvidenceLinkTarget: String, Codable, Hashable {
    case person
    case context
}

/// The lifecycle state of a single link suggestion.
public enum LinkSuggestionStatus: String, Codable, CaseIterable, Hashable {
    case pending
    case accepted
    case declined

    public var title: String {
        switch self {
        case .pending:  return "Pending"
        case .accepted: return "Accepted"
        case .declined: return "Declined"
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 8. Insights (embedded)
// ─────────────────────────────────────────────────────────────────────

/// The category of an insight card.  Shared between Person and
/// Context embedded insights and the Awareness bucketing logic.
public enum InsightKind: String, Codable, Hashable, CaseIterable, Sendable {
    case followUp
    case consentMissing
    case relationshipAtRisk
    case opportunity
    case complianceWarning
}

// Both embedded insight structs already carry every property that
// InsightDisplayable requires; these extensions just declare the
// conformance so InsightCardView<I> can accept them.
extension PersonInsight:  InsightDisplayable {}
extension ContextInsight: InsightDisplayable {}
// Note: SamInsight conformance to InsightDisplayable is in SAMModels.swift

// ─────────────────────────────────────────────────────────────────────
// MARK: - IntegrityStatus (design doc §integrity)
// ─────────────────────────────────────────────────────────────────────

/// Surfaces real-world changes without destructive deletion.  Will
/// be attached to `ContextParticipation`, `ConsentRequirement`,
/// `JointInterest`, and evidence linkage as the integrity-check layer
/// is implemented.
enum IntegrityStatus: String, Codable, CaseIterable {
    case valid
    case needsReview
    case orphaned
}

