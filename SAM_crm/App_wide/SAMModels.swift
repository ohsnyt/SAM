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
/// **Design-doc note:** the long-term target is to anchor identity
/// exclusively on `PersonRef` (a `CNContact.identifier` wrapper) and
/// never store a name or email.  Today, not every person has been
/// matched to a CNContact — people created from Inbox evidence start
/// as email-only — so `displayName` and `email` are stored here as
/// transitional fields.  `contactIdentifier` is the bridge: once set,
/// photo and name lookups use the fast CNContact path.
@Model
public final class SamPerson {
    @Attribute(.unique) public var id: UUID

    /// Human-readable name.  Sourced from CNContact when available;
    /// falls back to the email address for unverified people.
    public var displayName: String

    /// Role badges that appear next to the person's name in lists and
    /// detail views (e.g. "Client", "Referral Partner").
    public var roleBadges: [String]

    /// Stable `CNContact.identifier`.  `nil` until the person has been
    /// matched to a contact (see `ContactPhotoFetcher` and
    /// `ensurePersonExists`).
    public var contactIdentifier: String?

    /// A known email address.  Used as a fallback lookup key when
    /// `contactIdentifier` is not yet available.
    public var email: String?

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
        reviewAlertsCount: Int = 0
    ) {
        self.id                 = id
        self.displayName        = displayName
        self.roleBadges         = roleBadges
        self.contactIdentifier  = contactIdentifier
        self.email              = email
        self.consentAlertsCount = consentAlertsCount
        self.reviewAlertsCount  = reviewAlertsCount
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

    /// Insights that reference this evidence item as supporting material.
    /// Phase 3: inverse of SamInsight.basedOnEvidence.
    public var supportingInsights: [SamInsight] = []

    public init(
        id: UUID,
        state: EvidenceTriageState,
        sourceUID: String?        = nil,
        source: EvidenceSource,
        occurredAt: Date,
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
    public var message: String
    public var confidence: Double

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
        message: String,
        confidence: Double,
        basedOnEvidence: [SamEvidenceItem] = []
    ) {
        self.id = id
        self.samPerson = samPerson
        self.samContext = samContext
        self.product = product
        self.kind = kind
        self.message = message
        self.confidence = confidence
        self.basedOnEvidence = basedOnEvidence
        self.createdAt = .now
    }
}

