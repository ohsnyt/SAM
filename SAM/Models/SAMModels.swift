//
//  SAMModels.swift
//  SAM_crm
//
//  SwiftData @Model layer — Phase 1.
//
//  These classes mirror the live struct-based data exactly so that the
//  Phase-2 seed (and later, backup restore) can map 1-to-1 without
//  transformation logic.  Where the design doc (SAM_Core_Data_Model.md)
//  envisions a richer shape (e.g. full PersonRef-only identity, more
//  ContextType cases, standalone Interaction objects), a comment marks
//  the extension point.  Nothing is invented; everything here is already
//  exercised by the UI.
//

import SwiftData
import Foundation

// ─────────────────────────────────────────────────────────────────────
// MARK: - 1. Identity & People
// ─────────────────────────────────────────────────────────────────────

/// The CRM overlay for a person SAM knows about.
///
/// **Architecture (Phase 5 - Contacts-as-Identity):**
/// Apple Contacts is the system of record for identity. SamPerson stores
/// only `contactIdentifier` as anchor plus cached display fields for list
/// performance. Full CNContact data (family, contact info, dates) is
/// lazy-loaded in detail views via ContactSyncService.
@Model
public final class SamPerson {
    @Attribute(.unique) public var id: UUID

    /// Stable `CNContact.identifier`. Required for all active people.
    /// When nil, person is in temporary state (needs matching to contact).
    public var contactIdentifier: String?

    // ── Cached display fields (refreshed on sync) ───────────────────
    
    /// Human-readable name cached from CNContact for list performance.
    /// Refreshed by ContactSyncService when Contacts data changes.
    public var displayNameCache: String?
    
    /// Primary email cached from CNContact.emailAddresses.first
    public var emailCache: String?
    
    /// All known canonical email addresses for matching
    public var emailAliases: [String] = []

    /// All known canonical phone numbers for matching (last 10 digits, digits only)
    public var phoneAliases: [String] = []
    
    /// Thumbnail image cached from CNContact.thumbnailImageData
    public var photoThumbnailCache: Data?
    
    /// Timestamp of last successful cache refresh
    public var lastSyncedAt: Date?
    
    /// True when contact deleted externally; triggers "Unlinked" badge
    public var isArchived: Bool = false

    /// True when this person is the user's own "Me" contact card
    public var isMe: Bool = false

    // ── AI Relationship Summary (Phase L-2) ─────────────────────────

    /// LLM-generated overview of the relationship
    public var relationshipSummary: String?

    /// Top recurring themes from notes and interactions
    public var relationshipKeyThemes: [String] = []

    /// Actionable next steps synthesized from awareness items
    public var relationshipNextSteps: [String] = []

    /// When the relationship summary was last refreshed
    public var summaryUpdatedAt: Date?

    // ── DEPRECATED: Transitional fields (remove in SAM_v7) ─────────
    // These fields exist for backward compatibility during migration.
    // New code should use displayNameCache/emailCache instead.
    
    /// @deprecated Use displayNameCache
    public var displayName: String
    
    /// @deprecated Use emailCache
    public var email: String?

    /// Role badges that appear next to the person's name in lists and
    /// detail views (e.g. "Client", "Referral Partner").
    public var roleBadges: [String]

    // ── Alert counters (denormalised for list badges) ──────────────
    public var consentAlertsCount: Int
    public var reviewAlertsCount:  Int

    // ── Relationships ───────────────────────────────────────────────

    /// Contexts this person participates in.
    @Relationship(deleteRule: .nullify)
    public var participations: [ContextParticipation] = []

    /// Responsibility relationships where this person is the
    /// *responsible party* (guardian / decision-maker).
    @Relationship(deleteRule: .nullify)
    public var responsibilitiesAsGuardian: [Responsibility] = []

    /// Responsibility relationships where this person is the
    /// *dependent*.
    @Relationship(deleteRule: .nullify)
    public var responsibilitiesAsDependent: [Responsibility] = []

    /// Joint-interest groups this person belongs to.
    @Relationship(deleteRule: .nullify)
    public var jointInterests: [JointInterest] = []

    /// Coverage records across all products.
    @Relationship(deleteRule: .nullify)
    public var coverages: [Coverage] = []

    /// Consent requirements that name this person.
    @Relationship(deleteRule: .nullify)
    public var consentRequirements: [ConsentRequirement] = []

    /// Evidence items linked to this person (inverse of SamEvidenceItem.linkedPeople)
    @Relationship(deleteRule: .nullify, inverse: \SamEvidenceItem.linkedPeople)
    public var linkedEvidence: [SamEvidenceItem] = []

    /// Notes linked to this person (inverse of SamNote.linkedPeople)
    @Relationship(deleteRule: .nullify, inverse: \SamNote.linkedPeople)
    public var linkedNotes: [SamNote] = []

    // ── Referral tracking ────────────────────────────────────────────

    /// The person who referred this contact (e.g. an existing client
    /// who introduced a new lead). Nil when not referred or unknown.
    @Relationship(deleteRule: .nullify)
    public var referredBy: SamPerson?

    /// People this person has referred. Inverse of `referredBy`.
    @Relationship(deleteRule: .nullify, inverse: \SamPerson.referredBy)
    public var referrals: [SamPerson] = []

    // ── Embedded collections (not yet normalised into their own
    //    @Model classes — mirrors the current struct layout) ─────────

    /// Obligation notes shown in the People detail view.
    public var responsibilityNotes: [String] = []

    /// Recent-interaction chips shown in People detail.
    /// Will become a @Relationship to a standalone Interaction @Model
    /// once interactions are promoted (see design doc §12).
    public var recentInteractions: [InteractionChip] = []

    /// Insights surfaced on this person's detail card.
    @Relationship(deleteRule: .cascade, inverse: \SamInsight.samPerson)
    public var insights: [SamInsight] = []

    // ── Context chips (denormalised snapshot for list / search) ────
    /// Lightweight context membership chips.  Kept in sync with
    /// `participations` but stored flat so the People list can render
    /// without loading the full Context graph.
    var contextChips: [ContextChip] = []

    init(
        id: UUID,
        displayName: String,
        roleBadges: [String],
        contactIdentifier: String? = nil,
        email: String? = nil,
        consentAlertsCount: Int = 0,
        reviewAlertsCount: Int = 0,
        isMe: Bool = false
    ) {
        self.id                 = id
        self.displayName        = displayName
        self.displayNameCache   = displayName  // Initialize cache with current value
        self.roleBadges         = roleBadges
        self.contactIdentifier  = contactIdentifier
        self.email              = email
        self.emailCache         = email  // Initialize cache with current value
        self.consentAlertsCount = consentAlertsCount
        self.reviewAlertsCount  = reviewAlertsCount
        self.isArchived         = false
        self.isMe               = isMe
        self.lastSyncedAt       = nil
        self.photoThumbnailCache = nil
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 2. Contexts
// ─────────────────────────────────────────────────────────────────────

/// A relationship environment: household, business, or recruiting group.
///
/// **Design-doc note:** `ContextKind` will expand to the full
/// `ContextType` enum (personalPlanning, agentTeam, agentExternal,
/// referralPartner, vendor) as the UI adds support for those cases.
@Model
public final class SamContext {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var kind: ContextKind

    // ── Alert counters (denormalised) ───────────────────────────────
    public var consentAlertCount:  Int = 0
    public var reviewAlertCount:   Int = 0
    public var followUpAlertCount: Int = 0

    // ── Relationships ───────────────────────────────────────────────
    @Relationship(deleteRule: .cascade)
    public var participations: [ContextParticipation] = []

    @Relationship(deleteRule: .cascade)
    public var products: [Product] = []

    @Relationship(deleteRule: .cascade)
    public var consentRequirements: [ConsentRequirement] = []

    // ── Embedded collections (mirrors current struct) ──────────────
    /// Product cards shown on the context detail screen.
    /// Will become a pure @Relationship once Product is the single
    /// source of truth for status/subtitle.
    public var productCards: [ContextProductModel] = []

    /// Recent-interaction chips shown on context detail.
    public var recentInteractions: [InteractionModel] = []

    /// Evidence items linked to this context (inverse of SamEvidenceItem.linkedContexts)
    @Relationship(deleteRule: .nullify, inverse: \SamEvidenceItem.linkedContexts)
    public var linkedEvidence: [SamEvidenceItem] = []

    /// Notes linked to this context (inverse of SamNote.linkedContexts)
    @Relationship(deleteRule: .nullify, inverse: \SamNote.linkedContexts)
    public var linkedNotes: [SamNote] = []

    /// Insights surfaced on this context's detail card.
    @Relationship(deleteRule: .cascade, inverse: \SamInsight.samContext)
    public var insights: [SamInsight] = []

    public init(
        id: UUID,
        name: String,
        kind: ContextKind,
        consentAlertCount: Int  = 0,
        reviewAlertCount: Int   = 0,
        followUpAlertCount: Int = 0
    ) {
        self.id                 = id
        self.name               = name
        self.kind               = kind
        self.consentAlertCount  = consentAlertCount
        self.reviewAlertCount   = reviewAlertCount
        self.followUpAlertCount = followUpAlertCount
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 3. Participation (Person ↔ Context join)
// ─────────────────────────────────────────────────────────────────────

/// Records that a person participates in a context, with a role and
/// an optional time window.
@Model
public final class ContextParticipation {
    @Attribute(.unique) public var id: UUID

    public var person:  SamPerson?
    public var context: SamContext?

    /// The role(s) this person holds inside the context, rendered as
    /// badge strings (e.g. "Client", "Primary Insured").  Will migrate
    /// to a typed `RoleType` enum (see design doc §4) once the UI
    /// supports the full role vocabulary.
    public var roleBadges: [String] = []

    /// Whether this participant is the primary / named person for the
    /// context (drives sort order and layout in detail views).
    public var isPrimary: Bool = false

    /// A free-text annotation visible only on the context detail card
    /// (e.g. "Consent must be provided by guardian").
    public var note: String?

    public var startDate: Date
    public var endDate:   Date?

    public init(
        id: UUID,
        person: SamPerson,
        context: SamContext,
        roleBadges: [String] = [],
        isPrimary: Bool      = false,
        note: String?        = nil,
        startDate: Date      = .now
    ) {
        self.id         = id
        self.person     = person
        self.context    = context
        self.roleBadges = roleBadges
        self.isPrimary  = isPrimary
        self.note       = note
        self.startDate  = startDate
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 4. Responsibility (guardian ↔ dependent)
// ─────────────────────────────────────────────────────────────────────

/// An explicit, auditable link between a responsible person and a
/// dependent (minor, incapacitated adult, etc.).
@Model
public final class Responsibility {
    @Attribute(.unique) public var id: UUID

    public var guardian:  SamPerson?   // the responsible party
    public var dependent: SamPerson?   // the person they are responsible for

    /// Plain-English reason (e.g. "minor", "legal guardianship").
    public var reason: String

    public var startDate: Date
    public var endDate:   Date?

    public init(
        id: UUID,
        guardian: SamPerson,
        dependent: SamPerson,
        reason: String,
        startDate: Date = .now
    ) {
        self.id        = id
        self.guardian  = guardian
        self.dependent = dependent
        self.reason    = reason
        self.startDate = startDate
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 5. Joint Interest & Survivorship
// ─────────────────────────────────────────────────────────────────────

/// A group of people who share a joint legal or financial interest,
/// optionally with survivorship rights.
@Model
public final class JointInterest {
    @Attribute(.unique) public var id: UUID

    /// The people in this joint-interest group.
    @Relationship(deleteRule: .nullify)
    public var parties: [SamPerson] = []

    public var type: JointInterestType
    public var survivorshipRights: Bool

    public var startDate: Date
    public var endDate:   Date?
    public var notes:     String?

    /// Products to which this joint interest applies.
    @Relationship(deleteRule: .nullify)
    public var products: [Product] = []

    public init(
        id: UUID,
        parties: [SamPerson],
        type: JointInterestType,
        survivorshipRights: Bool,
        startDate: Date = .now
    ) {
        self.id                 = id
        self.parties            = parties
        self.type               = type
        self.survivorshipRights = survivorshipRights
        self.startDate          = startDate
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 6. Consent Requirements
// ─────────────────────────────────────────────────────────────────────

/// A legally or procedurally required approval.  Never implied;
/// always explicit, tracked, and auditable.
@Model
public final class ConsentRequirement {
    @Attribute(.unique) public var id: UUID

    /// The person who must consent.  `nil` when the requirement is
    /// described only as free text (legacy / not-yet-linked).
    public var person: SamPerson?

    /// The context this requirement belongs to (if any).
    public var context: SamContext?

    /// The product this requirement is attached to (if any).
    public var product: Product?

    /// Human-readable title already formatted for display
    /// (e.g. "Mary Smith (Spouse) must consent").
    public var title: String

    /// Why this consent is required.
    public var reason: String

    /// Optional regulatory jurisdiction code (e.g. "MO").
    public var jurisdiction: String?

    public var status: ConsentStatus

    public var requestedAt:  Date
    public var satisfiedAt:  Date?
    public var revokedAt:    Date?

    public init(
        id: UUID,
        title: String,
        reason: String,
        status: ConsentStatus     = .required,
        jurisdiction: String?     = nil,
        person: SamPerson?        = nil,
        context: SamContext?      = nil,
        product: Product?         = nil,
        requestedAt: Date         = .now
    ) {
        self.id          = id
        self.title       = title
        self.reason      = reason
        self.status      = status
        self.jurisdiction = jurisdiction
        self.person      = person
        self.context     = context
        self.product     = product
        self.requestedAt = requestedAt
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 7. Products / Policies
// ─────────────────────────────────────────────────────────────────────

/// An insurance or financial product associated with a context.
@Model
public final class Product {
    @Attribute(.unique) public var id: UUID

    public var context: SamContext?

    public var type: ProductType
    public var name: String

    /// Free-text subtitle shown on the context detail card
    /// (e.g. "Coverage review due after household change.").
    public var subtitle: String?

    /// Human-readable status badge (e.g. "Active", "Proposed").
    public var statusDisplay: String

    /// SF Symbol name for the product icon.
    public var icon: String

    public var issuedDate: Date?

    // ── Relationships ───────────────────────────────────────────────
    @Relationship(deleteRule: .cascade)
    public var coverages: [Coverage] = []

    @Relationship(deleteRule: .cascade)
    public var consentRequirements: [ConsentRequirement] = []

    @Relationship(deleteRule: .nullify)
    public var jointInterests: [JointInterest] = []

    public init(
        id: UUID,
        type: ProductType,
        name: String,
        statusDisplay: String = "Draft",
        icon: String          = "shield",
        subtitle: String?     = nil,
        context: SamContext?  = nil
    ) {
        self.id            = id
        self.type          = type
        self.name          = name
        self.statusDisplay = statusDisplay
        self.icon          = icon
        self.subtitle      = subtitle
        self.context       = context
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 8. Coverage
// ─────────────────────────────────────────────────────────────────────

/// Who is covered by a product, in what capacity, and whether
/// survivorship rights apply.
@Model
public final class Coverage {
    @Attribute(.unique) public var id: UUID

    public var person:  SamPerson?
    public var product: Product?

    public var role: CoverageRole
    public var survivorshipRights: Bool

    public init(
        id: UUID,
        person: SamPerson,
        product: Product,
        role: CoverageRole,
        survivorshipRights: Bool = false
    ) {
        self.id                 = id
        self.person             = person
        self.product            = product
        self.role               = role
        self.survivorshipRights = survivorshipRights
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 9. Evidence (Inbox)
// ─────────────────────────────────────────────────────────────────────

/// A raw fact ingested from an external source (Calendar, Mail, …).
/// Evidence is the substrate for signals, proposed links, and
/// ultimately insights.
///
/// Upsert key: `sourceUID`.  Pruning is driven by the source's
/// canonical UID set (see `CalendarImportCoordinator`).
@Model
public final class SamEvidenceItem {
    @Attribute(.unique) public var id: UUID

    /// Stable, source-provided identifier used for idempotent upsert.
    /// Format: `"eventkit:<calendarItemIdentifier>"` for Calendar,
    /// `"mail:<messageID>"` for Mail, etc.  `nil` for manually-created
    /// evidence.
    @Attribute(.unique) public var sourceUID: String?

    public var source: EvidenceSource

    /// Two-state triage: the user either needs to review this item
    /// or has finished with it.
    ///
    /// **Design-doc note:** the long-term inbox model (§10) envisions
    /// a richer `InboxStatus` (new / pinned / snoozed / archived /
    /// dismissed).  `EvidenceTriageState` will be replaced when the
    /// UI adds those states.
    ///
    /// **Implementation note:** Stored as raw string value to avoid
    /// SwiftData schema validation issues with RawRepresentable enums.
    /// The computed property provides type-safe enum access.
    public var stateRawValue: String
    
    @Transient
    public var state: EvidenceTriageState {
        get { EvidenceTriageState(rawValue: stateRawValue) ?? .needsReview }
        set { stateRawValue = newValue.rawValue }
    }

    // ── Core facts ──────────────────────────────────────────────────
    public var occurredAt: Date
    /// End time for calendar events. `nil` for non-calendar evidence.
    public var endedAt:    Date?
    public var title:      String
    public var snippet:    String
    public var bodyText:   String?

    // ── Computed signals (re-derived on every upsert) ──────────────
    /// Deterministic, explainable tags produced by `InsightGeneratorV1`.
    /// Stored as an embedded value array; not a separate table because
    /// they are always recomputed alongside the evidence facts and
    /// never queried independently.
    public var signals: [EvidenceSignal] = []

    // ── Participant hints (from the source event / message) ────────
    /// Raw attendee info as resolved at import time.  Verified
    /// participants have been matched to a CNContact; unverified ones
    /// are email-only placeholders.
    public var participantHints: [ParticipantHint] = []

    // ── Link proposals & confirmations ─────────────────────────────
    /// System-generated suggestions for linking this evidence to a
    /// person or context.  Each suggestion carries its own lifecycle
    /// (pending → accepted / declined).
    public var proposedLinks: [ProposedLink] = []

    /// UUIDs of confirmed person links (accepted suggestions or
    /// manual links).  Will become a `@Relationship` to `[SamPerson]`
    /// once the seed path is ready to resolve UUIDs into live objects.
    @Relationship(deleteRule: .nullify)
    public var linkedPeople: [SamPerson] = []

    /// UUIDs of confirmed context links.  Same migration note as
    /// `linkedPeople`.
    @Relationship(deleteRule: .nullify)
    public var linkedContexts: [SamContext] = []

    /// Notes linked to this evidence item (inverse of SamNote.linkedEvidence)
    @Relationship(deleteRule: .nullify, inverse: \SamNote.linkedEvidence)
    public var linkedNotes: [SamNote] = []

    /// Insights that reference this evidence item as supporting material.
    /// Phase 3: inverse of SamInsight.basedOnEvidence.
    public var supportingInsights: [SamInsight] = []

    public init(
        id: UUID,
        state: EvidenceTriageState,
        sourceUID: String?        = nil,
        source: EvidenceSource,
        occurredAt: Date,
        endedAt: Date?            = nil,
        title: String,
        snippet: String,
        bodyText: String?         = nil,
        participantHints: [ParticipantHint] = [],
        signals: [EvidenceSignal]           = [],
        proposedLinks: [ProposedLink]       = []
    ) {
        self.id               = id
        self.stateRawValue    = state.rawValue
        self.sourceUID        = sourceUID
        self.source           = source
        self.occurredAt       = occurredAt
        self.endedAt          = endedAt
        self.title            = title
        self.snippet          = snippet
        self.bodyText         = bodyText
        self.participantHints = participantHints
        self.signals          = signals
        self.proposedLinks    = proposedLinks
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 10. Insights (promoted from embedded value types)
// ─────────────────────────────────────────────────────────────────────
/// A persisted AI recommendation or observation attached to a person,
/// context, or product.
///
/// Phase 1: basic @Model with entity relationships and lifecycle.
/// Phase 3: replaced evidenceIDs with @Relationship to SamEvidenceItem.
@Model
public final class SamInsight {
    @Attribute(.unique) public var id: UUID

    // Relationships (entity this insight is about)
    public var samPerson: SamPerson?
    public var samContext: SamContext?
    public var product: Product?

    // Core properties
    public var kind: InsightKind
    public var title: String
    public var message: String          // Body text
    public var confidence: Double

    // Source tracking (for deduplication)
    public var urgencyRawValue: String
    public var sourceTypeRawValue: String
    public var sourceID: UUID?

    @Transient
    public var urgency: InsightPriority {
        get { InsightPriority(rawValue: Int(urgencyRawValue) ?? 2) ?? .medium }
        set { urgencyRawValue = String(newValue.rawValue) }
    }

    @Transient
    public var sourceType: InsightSourceType {
        get { InsightSourceType(rawValue: sourceTypeRawValue) ?? .pattern }
        set { sourceTypeRawValue = newValue.rawValue }
    }

    // Supporting evidence (Phase 3: proper relationship)
    @Relationship(deleteRule: .nullify, inverse: \SamEvidenceItem.supportingInsights)
    public var basedOnEvidence: [SamEvidenceItem] = []

    // Lifecycle
    public var createdAt: Date
    public var dismissedAt: Date?

    // Display helpers (computed from basedOnEvidence)
    public var interactionsCount: Int {
        basedOnEvidence.count
    }
    public var consentsCount: Int = 0

    public init(
        id: UUID = UUID(),
        samPerson: SamPerson? = nil,
        samContext: SamContext? = nil,
        product: Product? = nil,
        kind: InsightKind,
        title: String = "",
        message: String,
        confidence: Double,
        urgency: InsightPriority = .medium,
        sourceType: InsightSourceType = .pattern,
        sourceID: UUID? = nil,
        basedOnEvidence: [SamEvidenceItem] = []
    ) {
        self.id = id
        self.samPerson = samPerson
        self.samContext = samContext
        self.product = product
        self.kind = kind
        self.title = title
        self.message = message
        self.confidence = confidence
        self.urgencyRawValue = String(urgency.rawValue)
        self.sourceTypeRawValue = sourceType.rawValue
        self.sourceID = sourceID
        self.basedOnEvidence = basedOnEvidence
        self.createdAt = .now
    }
}

// MARK: - InsightDisplayable Conformance
extension SamInsight: InsightDisplayable {}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 11. Outcomes (Phase N: Coaching Engine)
// ─────────────────────────────────────────────────────────────────────

/// An outcome-focused coaching suggestion generated by the OutcomeEngine.
/// Combines deterministic scoring with AI enrichment to guide the user
/// toward specific relationship goals.
@Model
public final class SamOutcome {
    @Attribute(.unique) public var id: UUID

    /// Outcome title — concise, action-oriented (e.g., "Build IUL proposal for Sarah")
    public var title: String

    /// Why this outcome matters (e.g., "She expressed interest in security + growth. Meeting in 3 days.")
    public var rationale: String

    /// Stored as raw string for SwiftData; use `outcomeKind` transient property for type-safe access.
    public var outcomeKindRawValue: String

    /// Computed priority (0.0–1.0). Higher = more urgent/important.
    public var priorityScore: Double

    /// Hard deadline (e.g., meeting date, follow-up window end). Nil for open-ended outcomes.
    public var deadlineDate: Date?

    /// Stored as raw string for SwiftData; use `status` transient property.
    public var statusRawValue: String

    public var createdAt: Date
    public var completedAt: Date?
    public var dismissedAt: Date?

    /// When this outcome was last surfaced to the user in the queue.
    public var lastSurfacedAt: Date?

    /// Summary of what evidence drove this outcome (for deduplication and display).
    public var sourceInsightSummary: String

    /// Optional concrete first step (e.g., "Run it by John for external review").
    public var suggestedNextStep: String?

    /// Coaching encouragement message (adaptive based on CoachingProfile).
    public var encouragementNote: String?

    // ── Relationships ───────────────────────────────────────────────

    @Relationship(deleteRule: .nullify)
    public var linkedPerson: SamPerson?

    @Relationship(deleteRule: .nullify)
    public var linkedContext: SamContext?

    // ── Feedback ────────────────────────────────────────────────────

    /// User helpfulness rating (1–5). Nil if not yet rated.
    public var userRating: Int?

    /// Whether the user clicked through / completed this outcome.
    public var wasActedOn: Bool

    // ── Transient computed properties ───────────────────────────────

    @Transient
    public var outcomeKind: OutcomeKind {
        get { OutcomeKind(rawValue: outcomeKindRawValue) ?? .followUp }
        set { outcomeKindRawValue = newValue.rawValue }
    }

    @Transient
    public var status: OutcomeStatus {
        get { OutcomeStatus(rawValue: statusRawValue) ?? .pending }
        set { statusRawValue = newValue.rawValue }
    }

    public init(
        id: UUID = UUID(),
        title: String,
        rationale: String,
        outcomeKind: OutcomeKind,
        priorityScore: Double = 0.5,
        deadlineDate: Date? = nil,
        status: OutcomeStatus = .pending,
        sourceInsightSummary: String,
        suggestedNextStep: String? = nil,
        encouragementNote: String? = nil,
        linkedPerson: SamPerson? = nil,
        linkedContext: SamContext? = nil
    ) {
        self.id = id
        self.title = title
        self.rationale = rationale
        self.outcomeKindRawValue = outcomeKind.rawValue
        self.priorityScore = priorityScore
        self.deadlineDate = deadlineDate
        self.statusRawValue = status.rawValue
        self.createdAt = .now
        self.sourceInsightSummary = sourceInsightSummary
        self.suggestedNextStep = suggestedNextStep
        self.encouragementNote = encouragementNote
        self.linkedPerson = linkedPerson
        self.linkedContext = linkedContext
        self.wasActedOn = false
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 12. Coaching Profile (Phase N: Adaptive Coaching)
// ─────────────────────────────────────────────────────────────────────

/// Tracks the user's coaching preferences and feedback patterns.
/// Singleton record — only one profile exists per app instance.
@Model
public final class CoachingProfile {
    @Attribute(.unique) public var id: UUID

    /// Encouragement style: "direct", "supportive", "achievement", "analytical"
    public var encouragementStyle: String

    /// Which outcome kinds the user acts on most (raw values).
    public var preferredOutcomeKinds: [String]

    /// Which outcome kinds the user dismisses most (raw values).
    public var dismissPatterns: [String]

    /// Average time (minutes) from surfaced to completed.
    public var avgResponseTimeMinutes: Double

    /// Cumulative counters.
    public var totalActedOn: Int
    public var totalDismissed: Int
    public var totalRated: Int
    public var avgRating: Double

    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        encouragementStyle: String = "direct",
        preferredOutcomeKinds: [String] = [],
        dismissPatterns: [String] = [],
        avgResponseTimeMinutes: Double = 0,
        totalActedOn: Int = 0,
        totalDismissed: Int = 0,
        totalRated: Int = 0,
        avgRating: Double = 0,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.encouragementStyle = encouragementStyle
        self.preferredOutcomeKinds = preferredOutcomeKinds
        self.dismissPatterns = dismissPatterns
        self.avgResponseTimeMinutes = avgResponseTimeMinutes
        self.totalActedOn = totalActedOn
        self.totalDismissed = totalDismissed
        self.totalRated = totalRated
        self.avgRating = avgRating
        self.updatedAt = updatedAt
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted when a SamPerson's data changes (e.g. role badges edited).
    /// Listeners should refresh their people data.
    static let samPersonDidChange = Notification.Name("samPersonDidChange")

    /// Posted to navigate to a person's detail view from any screen.
    /// userInfo: ["personID": UUID]
    static let samNavigateToPerson = Notification.Name("samNavigateToPerson")
}

