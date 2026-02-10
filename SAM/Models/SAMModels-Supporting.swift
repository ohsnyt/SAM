//
//  SAMModels-Supporting.swift
//  SAM_crm
//
//  Created by Assistant on 2/9/26.
//  Clean rebuild - Phase A: Foundation
//
//  Supporting types for SAMModels.swift
//  - Enums: ContextKind, EvidenceSource, InsightKind, ProductType, etc.
//  - Value types: ParticipantHint, EvidenceSignal, ProposedLink, etc.
//

import Foundation

// ─────────────────────────────────────────────────────────────────────
// MARK: - Context Types
// ─────────────────────────────────────────────────────────────────────

public enum ContextKind: String, Codable, Sendable {
    case household = "Household"
    case business = "Business"
    case recruiting = "Recruiting"
    case personalPlanning = "Personal Planning"
    case agentTeam = "Agent Team"
    case agentExternal = "External Agent"
    case referralPartner = "Referral Partner"
    case vendor = "Vendor"
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Evidence Types
// ─────────────────────────────────────────────────────────────────────

public enum EvidenceSource: String, Codable, Sendable {
    case calendar = "Calendar"
    case mail = "Mail"
    case contacts = "Contacts"
    case note = "Note"
    case manual = "Manual"
}

public enum EvidenceTriageState: String, Codable, Sendable {
    case needsReview = "needsReview"
    case done = "done"
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Product Types
// ─────────────────────────────────────────────────────────────────────

public enum ProductType: String, Codable, Sendable {
    case lifeInsurance = "Life Insurance"
    case annuity = "Annuity"
    case retirement401k = "401(k)"
    case retirementIRA = "IRA"
    case disability = "Disability Insurance"
    case longTermCare = "Long-Term Care"
    case other = "Other"
}

public enum CoverageRole: String, Codable, Sendable {
    case primaryInsured = "Primary Insured"
    case beneficiary = "Beneficiary"
    case contingentBeneficiary = "Contingent Beneficiary"
    case owner = "Owner"
    case payor = "Payor"
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Consent & Compliance
// ─────────────────────────────────────────────────────────────────────

public enum ConsentStatus: String, Codable, Sendable {
    case required = "Required"
    case pending = "Pending"
    case satisfied = "Satisfied"
    case revoked = "Revoked"
    case notRequired = "Not Required"
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Joint Interest
// ─────────────────────────────────────────────────────────────────────

public enum JointInterestType: String, Codable, Sendable {
    case jointTenancy = "Joint Tenancy"
    case tenancyInCommon = "Tenancy in Common"
    case communityProperty = "Community Property"
    case trust = "Trust"
    case other = "Other"
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Insight Types
// ─────────────────────────────────────────────────────────────────────

public enum InsightKind: String, Codable, Sendable {
    case relationshipAtRisk = "Relationship at Risk"
    case consentMissing = "Consent Missing"
    case complianceWarning = "Compliance Warning"
    case opportunity = "Opportunity"
    case followUpNeeded = "Follow-Up Needed"
    case informational = "Informational"
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Value Types (Embedded in Models)
// ─────────────────────────────────────────────────────────────────────

/// Participant information extracted from calendar events or messages
public struct ParticipantHint: Codable, Sendable {
    public var displayName: String
    public var isOrganizer: Bool
    public var isVerified: Bool      // True if matched to CNContact
    public var rawEmail: String?
    
    public init(displayName: String, isOrganizer: Bool = false, isVerified: Bool = false, rawEmail: String? = nil) {
        self.displayName = displayName
        self.isOrganizer = isOrganizer
        self.isVerified = isVerified
        self.rawEmail = rawEmail
    }
}

/// Deterministic signal extracted from evidence
public struct EvidenceSignal: Codable, Sendable, Identifiable {
    public var id: UUID
    public var type: SignalType
    public var message: String
    public var confidence: Double
    
    public init(id: UUID = UUID(), type: SignalType, message: String, confidence: Double) {
        self.id = id
        self.type = type
        self.message = message
        self.confidence = confidence
    }
    
    public enum SignalType: String, Codable, Sendable {
        case relationshipChange = "Relationship Change"
        case financialEvent = "Financial Event"
        case lifeEvent = "Life Event"
        case contactFrequency = "Contact Frequency"
        case complianceRisk = "Compliance Risk"
        case opportunity = "Opportunity"
    }
}

/// AI-proposed link between evidence and entity
public struct ProposedLink: Codable, Sendable, Identifiable {
    public var id: UUID
    public var targetType: TargetType
    public var targetID: UUID
    public var targetName: String
    public var reason: String
    public var confidence: Double
    public var status: LinkStatus
    
    public init(
        id: UUID = UUID(),
        targetType: TargetType,
        targetID: UUID,
        targetName: String,
        reason: String,
        confidence: Double,
        status: LinkStatus = .pending
    ) {
        self.id = id
        self.targetType = targetType
        self.targetID = targetID
        self.targetName = targetName
        self.reason = reason
        self.confidence = confidence
        self.status = status
    }
    
    public enum TargetType: String, Codable, Sendable {
        case person = "Person"
        case context = "Context"
    }
    
    public enum LinkStatus: String, Codable, Sendable {
        case pending = "Pending"
        case accepted = "Accepted"
        case declined = "Declined"
    }
}

/// Lightweight context chip for person list view
public struct ContextChip: Codable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: ContextKind
    public var icon: String
    
    public init(id: UUID, name: String, kind: ContextKind, icon: String) {
        self.id = id
        self.name = name
        self.kind = kind
        self.icon = icon
    }
    
    public var kindDisplay: String {
        kind.rawValue
    }
}

/// Recent interaction chip for person detail view
public struct InteractionChip: Codable, Sendable, Identifiable {
    public var id: UUID
    public var type: String
    public var icon: String
    public var timestamp: Date
    public var title: String
    
    public init(id: UUID = UUID(), type: String, icon: String, timestamp: Date, title: String) {
        self.id = id
        self.type = type
        self.icon = icon
        self.timestamp = timestamp
        self.title = title
    }
}

/// Product card for context detail view
public struct ContextProductModel: Codable, Sendable, Identifiable {
    public var id: UUID
    public var type: ProductType
    public var name: String
    public var subtitle: String?
    public var statusDisplay: String
    public var icon: String
    
    public init(
        id: UUID,
        type: ProductType,
        name: String,
        subtitle: String? = nil,
        statusDisplay: String,
        icon: String
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.subtitle = subtitle
        self.statusDisplay = statusDisplay
        self.icon = icon
    }
}

/// Recent interaction model for context detail view
public struct InteractionModel: Codable, Sendable, Identifiable {
    public var id: UUID
    public var type: String
    public var icon: String
    public var timestamp: Date
    public var title: String
    public var participants: [String]
    
    public init(
        id: UUID = UUID(),
        type: String,
        icon: String,
        timestamp: Date,
        title: String,
        participants: [String] = []
    ) {
        self.id = id
        self.type = type
        self.icon = icon
        self.timestamp = timestamp
        self.title = title
        self.participants = participants
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Protocols
// ─────────────────────────────────────────────────────────────────────

/// Protocol for types that can be displayed as insights in the UI
public protocol InsightDisplayable {
    var kind: InsightKind { get }
    var message: String { get }
    var confidence: Double { get }
    var interactionsCount: Int { get }
    var consentsCount: Int { get }
}
