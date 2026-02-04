# SAM Core Data Model (SwiftData-Friendly)

This document describes the core data model for **SAM**, a cognitive assistant for relationship management designed for independent financial strategists.

The model is intentionally **relationship-first**, **context-aware**, and **Apple-native**, with identity anchored in Apple Contacts and all CRM intelligence owned locally by SAM.

---

## Design Principles

- Apple Contacts is the **system of record** for identity
- SAM never duplicates identity data
- People participate in multiple contexts simultaneously
- Roles are contextual, temporal, and reversible
- Consent, responsibility, and survivorship are first-class concepts
- Consent requirements are modeled as standalone, auditable objects with lifecycle state.
- Model reality first; UI emerges naturally
- Joint interests, interactions, and AI insights are first-class objects with explicit explainability.

---

## 1. PersonRef (External Identity)

```swift
struct PersonRef: Codable, Hashable {
    let contactIdentifier: String // CNContact.identifier
}
```

- Immutable reference to Apple Contacts
- No names, emails, addresses, or phone numbers stored in SAM

---

## 2. SamContact (CRM Overlay)

```swift
@Model
final class SamContact {
    @Attribute(.unique) var id: UUID
    var personRef: PersonRef

    var createdAt: Date
    var lastInteractionAt: Date?

    // Aggregated / derived
    var relationshipHealthScore: Double?
    var notesSummary: String?

    @Relationship(deleteRule: .cascade)
    var contexts: [ContextParticipation]

    @Relationship(deleteRule: .cascade)
    var insights: [Insight]

    init(personRef: PersonRef) {
        self.id = UUID()
        self.personRef = personRef
        self.createdAt = Date()
        self.contexts = []
        self.insights = []
    }
}
```

SamContact represents **how the strategist relates to a person**, not who the person is.

---

## 3. Context

Contexts represent the **environment** in which relationships exist.

```swift
enum ContextType: String, Codable {
    case personalPlanning
    case household
    case business
    case recruiting
    case agentTeam
    case agentExternal
    case referralPartner
    case vendor
}
```

```swift
@Model
final class Context {
    @Attribute(.unique) var id: UUID
    var type: ContextType
    var name: String
    var createdAt: Date
    var isActive: Bool

    @Relationship(deleteRule: .cascade)
    var participants: [ContextParticipation]

    @Relationship(deleteRule: .cascade)
    var products: [Product]

    init(type: ContextType, name: String) {
        self.id = UUID()
        self.type = type
        self.name = name
        self.createdAt = Date()
        self.isActive = true
        self.participants = []
        self.products = []
    }
}
```

Examples:
- Household: "John & Mary Smith"
- Business: "ABC Manufacturing, LLC"
- Recruiting: "Alex Chen – Pipeline"

---

## 4. Roles & Participation

Roles define **who a person is within a context**.

```swift
enum RoleType: String, Codable {
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
```

```swift
@Model
final class ContextParticipation {
    @Attribute(.unique) var id: UUID

    var samContact: SamContact
    var role: RoleType

    var startDate: Date
    var endDate: Date?

    init(contact: SamContact, role: RoleType) {
        self.id = UUID()
        self.samContact = contact
        self.role = role
        self.startDate = Date()
    }
}
```

This structure supports:
- Adults responsible for dependents
- Children or incapacitated adults
- Temporal role changes (e.g., child becomes adult)

---

## 5. Responsible Person / Dependent Relationship

Responsibility relationships are explicit and auditable.

```swift
@Model
final class Responsibility {
    @Attribute(.unique) var id: UUID

    var responsiblePerson: SamContact
    var dependent: SamContact

    var reason: String // minor, incapacity, legal guardianship
    var startDate: Date
    var endDate: Date?

    init(responsible: SamContact, dependent: SamContact, reason: String) {
        self.id = UUID()
        self.responsiblePerson = responsible
        self.dependent = dependent
        self.reason = reason
        self.startDate = Date()
    }
}
```

This allows SAM to:
- Route consent requirements correctly
- Prevent invalid signatures
- Explain regulatory constraints to the user

---

## 5a. Joint Interest & Survivorship

```swift
enum JointInterestType: String, Codable {
    case spousal
    case trustBeneficiaries
    case businessPartners
    case parentChild
}
```

```swift
@Model
final class JointInterest {
    @Attribute(.unique) var id: UUID

    var parties: [SamContact]
    var type: JointInterestType
    var survivorshipRights: Bool

    var startDate: Date
    var endDate: Date?
    var notes: String?

    init(parties: [SamContact],
         type: JointInterestType,
         survivorshipRights: Bool) {
        self.id = UUID()
        self.parties = parties
        self.type = type
        self.survivorshipRights = survivorshipRights
        self.startDate = Date()
    }
}
```

Survivorship is a relationship-level concept that may span multiple products, allowing the model to represent joint interests and rights that extend across different policies or financial instruments.

---

## 6. ConsentRequirement (First-Class Object)

ConsentRequirement represents a legally or procedurally required approval by a specific person, acting in a specific role, within a defined context or product lifecycle. Consent is never implied; it must be explicitly satisfied, tracked, and auditable.

```swift
enum ConsentStatus: String, Codable {
    case required
    case satisfied
    case revoked
    case expired
}
```

```swift
@Model
final class ConsentRequirement {
    @Attribute(.unique) var id: UUID

    // Who must consent
    var samContact: SamContact
    var requiredRole: RoleType

    // Why consent is required
    var reason: String            // e.g. joint spousal consent, guardian approval
    var jurisdiction: String?     // optional regulatory scope

    // Lifecycle
    var status: ConsentStatus
    var requestedAt: Date
    var satisfiedAt: Date?
    var revokedAt: Date?

    init(contact: SamContact,
         requiredRole: RoleType,
         reason: String,
         jurisdiction: String? = nil) {
        self.id = UUID()
        self.samContact = contact
        self.requiredRole = requiredRole
        self.reason = reason
        self.jurisdiction = jurisdiction
        self.status = .required
        self.requestedAt = Date()
    }
}
```

---

## 7. Product / Policy

```swift
enum ProductType: String, Codable {
    case lifeInsurance
    case disability
    case buySell
    case keyPerson
    case retirement
    case annuity
    case longTermCare
    case collegeSavings
    case trusts
}
```

```swift
@Model
final class Product {
    @Attribute(.unique) var id: UUID
    var type: ProductType
    var name: String
    var issuedDate: Date?
    var status: String

    @Relationship(deleteRule: .cascade)
    var coverages: [Coverage]

    @Relationship(deleteRule: .cascade)
    var consentRequirements: [ConsentRequirement]

    @Relationship(deleteRule: .nullify)
    var jointInterests: [JointInterest]

    init(type: ProductType, name: String) {
        self.id = UUID()
        self.type = type
        self.name = name
        self.status = "Draft"
        self.coverages = []
        self.consentRequirements = []
        self.jointInterests = []
    }
}
```

---

## 8. Coverage & Survivorship

```swift
enum CoverageRole: String, Codable {
    case insured
    case beneficiary
    case jointBeneficiary
}
```

```swift
@Model
final class Coverage {
    @Attribute(.unique) var id: UUID

    var samContact: SamContact
    var role: CoverageRole
    var survivorshipRights: Bool

    init(contact: SamContact, role: CoverageRole, survivorshipRights: Bool = false) {
        self.id = UUID()
        self.samContact = contact
        self.role = role
        self.survivorshipRights = survivorshipRights
    }
}
```

---

## 9. Interaction (Unified Communication Model)

```swift
enum InteractionType: String, Codable {
    case email
    case call
    case meeting
    case message
}
```

```swift
@Model
final class Interaction {
    @Attribute(.unique) var id: UUID

    var type: InteractionType
    var occurredAt: Date
    var durationSeconds: Int?

    var participants: [SamContact]
    var contexts: [Context]

    var calendarEventID: String?
    var mailMessageID: String?
    var zoomMeetingID: String?

    var summary: String?
    var sentimentScore: Double?
    var followUpSuggested: Bool

    init(type: InteractionType,
         occurredAt: Date,
         participants: [SamContact]) {
        self.id = UUID()
        self.type = type
        self.occurredAt = occurredAt
        self.participants = participants
        self.contexts = []
        self.followUpSuggested = false
    }
}
```

---

## 10. AI Insight & Recommendation

```swift
enum InsightType: String, Codable {
    case followUp
    case consentMissing
    case relationshipAtRisk
    case opportunity
    case complianceWarning
}
```

```swift
@Model
final class Insight {
    @Attribute(.unique) var id: UUID

    var samContact: SamContact?
    var context: Context?
    var product: Product?

    var type: InsightType
    var message: String
    var confidence: Double

    var basedOnInteractions: [Interaction]
    var basedOnConsents: [ConsentRequirement]

    var createdAt: Date
    var dismissedAt: Date?

    init(type: InsightType,
         message: String,
         confidence: Double) {
        self.id = UUID()
        self.type = type
        self.message = message
        self.confidence = confidence
        self.createdAt = Date()
        self.basedOnInteractions = []
        self.basedOnConsents = []
    }
}
```

---

## Integrity & Conflict Awareness

```swift
enum IntegrityStatus: String, Codable {
    case valid
    case needsReview
    case orphaned
}
```

This status may be attached to ContextParticipation, ConsentRequirement, and JointInterest to surface real-world changes without destructive deletion.

---

## Why This Model Works

- Handles families, businesses, recruiting, and compliance cleanly
- Supports joint beneficiaries and survivorship
- Supports minors and incapacitated adults
- Enables explainable AI reasoning
- Scales without schema collapse
- Treats consent as a durable domain object rather than a transient checkbox, enabling compliance, AI reasoning, and auditability.
- Makes survivorship, consent, and joint authority explicit rather than implicit
- Provides explainable AI recommendations grounded in concrete interactions and obligations
- Handles real-world change without silent data loss

> SAM does not manage customers.  
> SAM manages **relationships, roles, contexts, and obligations**.

---

# SAM Core Data Model

This document describes the core domain model for **SAM**, a cognitive assistant for relationship management designed for independent financial strategists.

SAM is:
- **Relationship-first** and **context-aware**
- **Apple-native** (Contacts + Calendar + Mail as primary sources)
- **Local-first** (intelligence and derived data owned locally)

This model is written to be **SwiftData-friendly**, while separating:
1) **External identity** (Apple Contacts) from
2) **SAM’s overlay** (relationship context, evidence, interactions, signals, insights)

---

## Design principles

- **Apple Contacts is the system of record** for identity.
- SAM does **not** duplicate contact identity data.
- People participate in multiple contexts simultaneously.
- Roles are contextual, temporal, and reversible.
- Consent, responsibility, and survivorship are first-class concepts.
- Evidence is **immutable-ish** (append-only, with pruning by source-of-truth UID sets).
- Intelligence outputs are **explainable**: every insight points to supporting evidence.

---

## 1) External Identity

### PersonRef (Apple Contacts reference)

```swift
struct PersonRef: Codable, Hashable {
    let contactIdentifier: String // CNContact.identifier
}
```

- Immutable reference to Apple Contacts.
- No names, emails, addresses, or phone numbers stored in SAM.

---

## 2) SAM Contact Overlay

### SamContact (CRM overlay anchored to PersonRef)

```swift
@Model
final class SamContact {
    @Attribute(.unique) var id: UUID
    var personRef: PersonRef

    var createdAt: Date
    var lastInteractionAt: Date?

    // Aggregated / derived
    var relationshipHealthScore: Double?
    var notesSummary: String?

    @Relationship(deleteRule: .cascade)
    var contexts: [ContextParticipation]

    @Relationship(deleteRule: .cascade)
    var insights: [Insight]

    init(personRef: PersonRef) {
        self.id = UUID()
        self.personRef = personRef
        self.createdAt = Date()
        self.contexts = []
        self.insights = []
    }
}
```

SamContact represents **how the strategist relates to a person**, not who the person is.

---

## 3) Contexts

Contexts represent the environment in which relationships exist.

```swift
enum ContextType: String, Codable {
    case personalPlanning
    case household
    case business
    case recruiting
    case agentTeam
    case agentExternal
    case referralPartner
    case vendor
}
```

```swift
@Model
final class Context {
    @Attribute(.unique) var id: UUID
    var type: ContextType
    var name: String
    var createdAt: Date
    var isActive: Bool

    @Relationship(deleteRule: .cascade)
    var participants: [ContextParticipation]

    @Relationship(deleteRule: .cascade)
    var products: [Product]

    init(type: ContextType, name: String) {
        self.id = UUID()
        self.type = type
        self.name = name
        self.createdAt = Date()
        self.isActive = true
        self.participants = []
        self.products = []
    }
}
```

Examples:
- Household: "John & Mary Smith"
- Business: "ABC Manufacturing, LLC"
- Recruiting: "Alex Chen – Pipeline"

---

## 4) Roles & Participation

```swift
enum RoleType: String, Codable {
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
```

```swift
@Model
final class ContextParticipation {
    @Attribute(.unique) var id: UUID

    var samContact: SamContact
    var role: RoleType

    var startDate: Date
    var endDate: Date?

    init(contact: SamContact, role: RoleType) {
        self.id = UUID()
        self.samContact = contact
        self.role = role
        self.startDate = Date()
    }
}
```

---

## 5) Responsibility (Responsible Person / Dependent)

Responsibility relationships are explicit and auditable.

```swift
@Model
final class Responsibility {
    @Attribute(.unique) var id: UUID

    var responsiblePerson: SamContact
    var dependent: SamContact

    var reason: String // minor, incapacity, legal guardianship
    var startDate: Date
    var endDate: Date?

    init(responsible: SamContact, dependent: SamContact, reason: String) {
        self.id = UUID()
        self.responsiblePerson = responsible
        self.dependent = dependent
        self.reason = reason
        self.startDate = Date()
    }
}
```

---

## 6) Joint Interest & Survivorship

```swift
enum JointInterestType: String, Codable {
    case spousal
    case trustBeneficiaries
    case businessPartners
    case parentChild
}
```

```swift
@Model
final class JointInterest {
    @Attribute(.unique) var id: UUID

    var parties: [SamContact]
    var type: JointInterestType
    var survivorshipRights: Bool

    var startDate: Date
    var endDate: Date?
    var notes: String?

    init(parties: [SamContact],
         type: JointInterestType,
         survivorshipRights: Bool) {
        self.id = UUID()
        self.parties = parties
        self.type = type
        self.survivorshipRights = survivorshipRights
        self.startDate = Date()
    }
}
```

---

## 7) Consent Requirement

Consent is never implied; it must be explicitly satisfied, tracked, and auditable.

```swift
enum ConsentStatus: String, Codable {
    case required
    case satisfied
    case revoked
    case expired
}
```

```swift
@Model
final class ConsentRequirement {
    @Attribute(.unique) var id: UUID

    // Who must consent
    var samContact: SamContact
    var requiredRole: RoleType

    // Why consent is required
    var reason: String            // e.g. joint spousal consent, guardian approval
    var jurisdiction: String?     // optional regulatory scope

    // Lifecycle
    var status: ConsentStatus
    var requestedAt: Date
    var satisfiedAt: Date?
    var revokedAt: Date?

    init(contact: SamContact,
         requiredRole: RoleType,
         reason: String,
         jurisdiction: String? = nil) {
        self.id = UUID()
        self.samContact = contact
        self.requiredRole = requiredRole
        self.reason = reason
        self.jurisdiction = jurisdiction
        self.status = .required
        self.requestedAt = Date()
    }
}
```

---

## 8) Product / Policy

```swift
enum ProductType: String, Codable {
    case lifeInsurance
    case disability
    case buySell
    case keyPerson
    case retirement
    case annuity
    case longTermCare
    case collegeSavings
    case trusts
}
```

```swift
@Model
final class Product {
    @Attribute(.unique) var id: UUID
    var type: ProductType
    var name: String
    var issuedDate: Date?
    var status: String

    @Relationship(deleteRule: .cascade)
    var coverages: [Coverage]

    @Relationship(deleteRule: .cascade)
    var consentRequirements: [ConsentRequirement]

    @Relationship(deleteRule: .nullify)
    var jointInterests: [JointInterest]

    init(type: ProductType, name: String) {
        self.id = UUID()
        self.type = type
        self.name = name
        self.status = "Draft"
        self.coverages = []
        self.consentRequirements = []
        self.jointInterests = []
    }
}
```

---

## 9) Coverage (including survivorship)

```swift
enum CoverageRole: String, Codable {
    case insured
    case beneficiary
    case jointBeneficiary
}
```

```swift
@Model
final class Coverage {
    @Attribute(.unique) var id: UUID

    var samContact: SamContact
    var role: CoverageRole
    var survivorshipRights: Bool

    init(contact: SamContact, role: CoverageRole, survivorshipRights: Bool = false) {
        self.id = UUID()
        self.samContact = contact
        self.role = role
        self.survivorshipRights = survivorshipRights
    }
}
```

---

## 10) Evidence (Inbox-level raw facts)

SAM ingests **evidence** from Apple sources (Calendar, Mail, Messages, etc.). Evidence is the raw substrate for interactions and insights.

### EvidenceSource

```swift
enum EvidenceSource: String, Codable {
    case calendar
    case mail
    case message
    case note
    case manual
}
```

### EvidenceItem

```swift
@Model
final class EvidenceItem {
    @Attribute(.unique) var id: UUID

    // Stable, source-provided identifier (or a deterministic derivation)
    @Attribute(.unique) var sourceUID: String
    var source: EvidenceSource

    // Core facts
    var occurredAt: Date
    var title: String
    var snippet: String
    var bodyText: String

    // Optional linkage
    var calendarEventID: String?
    var mailMessageID: String?

    // Derived
    var signals: [EvidenceSignal]

    // Triage
    var inboxStatus: InboxStatus
    var createdAt: Date

    init(sourceUID: String,
         source: EvidenceSource,
         occurredAt: Date,
         title: String,
         snippet: String,
         bodyText: String) {
        self.id = UUID()
        self.sourceUID = sourceUID
        self.source = source
        self.occurredAt = occurredAt
        self.title = title
        self.snippet = snippet
        self.bodyText = bodyText
        self.signals = []
        self.inboxStatus = .new
        self.createdAt = Date()
    }
}
```

### InboxStatus

```swift
enum InboxStatus: String, Codable {
    case new
    case pinned
    case snoozed
    case archived
    case dismissed
}
```

**Key behavior:** Evidence ingestion must be *idempotent*.
- **Upsert** by `sourceUID`.
- Maintain a `currentUIDs` set per sync cycle and **prune** items not present (when appropriate).

---

## 11) Evidence Signals (lightweight intelligence primitives)

Signals are deterministic, explainable tags computed from an EvidenceItem.

```swift
struct EvidenceSignal: Codable, Hashable {
    var kind: String          // e.g. "follow_up", "deadline", "meeting", "compliance"
    var confidence: Double    // 0...1
    var reasons: [String]     // short explanations (no long prose)
}
```

Signals are designed to be:
- Fast, local, and deterministic
- Stable inputs to higher-level Insight generation

---

## 12) Interaction (unified communication object)

Interactions are deduced or curated from evidence. Multiple evidence items may compose one interaction.

```swift
enum InteractionType: String, Codable {
    case email
    case call
    case meeting
    case message
    case note
}
```

```swift
@Model
final class Interaction {
    @Attribute(.unique) var id: UUID

    var type: InteractionType
    var occurredAt: Date
    var durationSeconds: Int?

    // Who + where
    var participants: [SamContact]
    var contexts: [Context]

    // Source links
    var calendarEventID: String?
    var mailMessageID: String?

    // Explainability
    var evidence: [EvidenceItem]

    // Derived
    var summary: String?
    var sentimentScore: Double?
    var followUpSuggested: Bool

    init(type: InteractionType,
         occurredAt: Date,
         participants: [SamContact]) {
        self.id = UUID()
        self.type = type
        self.occurredAt = occurredAt
        self.participants = participants
        self.contexts = []
        self.evidence = []
        self.followUpSuggested = false
    }
}
```

---

## 13) AI Insight (actionable recommendations)

Insights are user-facing recommendations grounded in Interactions, Evidence, and Compliance objects.

```swift
enum InsightType: String, Codable {
    case followUp
    case consentMissing
    case relationshipAtRisk
    case opportunity
    case complianceWarning
}
```

```swift
@Model
final class Insight {
    @Attribute(.unique) var id: UUID

    var samContact: SamContact?
    var context: Context?
    var product: Product?

    var type: InsightType
    var message: String
    var confidence: Double

    // Explainability links
    var basedOnInteractions: [Interaction]
    var basedOnEvidence: [EvidenceItem]
    var basedOnConsents: [ConsentRequirement]

    // Lifecycle
    var createdAt: Date
    var dismissedAt: Date?

    init(type: InsightType,
         message: String,
         confidence: Double) {
        self.id = UUID()
        self.type = type
        self.message = message
        self.confidence = confidence
        self.createdAt = Date()
        self.basedOnInteractions = []
        self.basedOnEvidence = []
        self.basedOnConsents = []
    }
}
```

---

## Integrity & conflict awareness

```swift
enum IntegrityStatus: String, Codable {
    case valid
    case needsReview
    case orphaned
}
```

This status may be attached to ContextParticipation, ConsentRequirement, JointInterest, and Evidence linkage to surface real-world changes without destructive deletion.

---

## Why this model works

- Handles families, businesses, recruiting, and compliance cleanly
- Makes survivorship and consent explicit
- Supports minors and incapacitated adults
- Treats Evidence as first-class, enabling explainable intelligence
- Enables a staged intelligence approach: **Signals → Interactions → Insights**

> SAM does not manage customers.
> SAM manages **relationships, roles, contexts, obligations, and evidence-grounded intelligence**.
