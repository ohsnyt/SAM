# SAM CRM - Data Model Architecture

## Document Purpose

This document provides a comprehensive overview of the data models used throughout SAM CRM, their relationships, access patterns, and integration with SwiftData.

**Last Updated:** February 9, 2026  
**SwiftData Schema Version:** SAM_v6  
**Swift Version:** Swift 6.0+

---

## Table of Contents

1. [Schema Overview](#schema-overview)
2. [Model Container Architecture](#model-container-architecture)
3. [Core Models](#core-models)
4. [Model Relationships](#model-relationships)
5. [Access Patterns](#access-patterns)
6. [Concurrency Considerations](#concurrency-considerations)
7. [Migration Notes](#migration-notes)

---

## Schema Overview

### All Models

SAM CRM uses SwiftData with the following model classes:

```swift
enum SAMSchema {
    nonisolated static let allModels: [any PersistentModel.Type] = [
        // Identity & People
        SamPerson.self,
        
        // Contexts & Relationships
        SamContext.self,
        ContextParticipation.self,
        Responsibility.self,
        JointInterest.self,
        
        // Products & Coverage
        Product.self,
        Coverage.self,
        ConsentRequirement.self,
        
        // Evidence & Intelligence
        SamEvidenceItem.self,
        SamInsight.self,
        
        // Notes & Analysis
        SamNote.self,
        SamAnalysisArtifact.self,
    ]
}
```

### Schema Evolution

**Current Version:** `SAM_v6`

v6 additions:
- Structured entity storage (`peopleJSON`, `topicsJSON`, `actions`)
- LLM tracking (`usedLLM`)
- Analysis artifact storage

---

## Model Container Architecture

### Singleton Container

```swift
enum SAMModelContainer {
    /// Shared ModelContainer for the entire app
    nonisolated static let shared: ModelContainer = {
        let schema = Schema(SAMSchema.allModels)
        let config = ModelConfiguration(
            "SAM_v6",
            schema: schema,
            isStoredInMemoryOnly: false
        )
        return try! ModelContainer(for: schema, configurations: config)
    }()
    
    /// Create a fresh ModelContext for an actor
    nonisolated static func newContext() -> ModelContext {
        ModelContext(shared)
    }
}
```

### Usage Pattern

```swift
// ✅ CORRECT: Each actor creates its own context
@MainActor
func doMainActorWork() {
    let ctx = SAMModelContainer.newContext()
    // Use ctx...
}

actor Worker {
    private let context: ModelContext
    
    init() {
        self.context = SAMModelContainer.newContext()
    }
    
    func doWork() async {
        // Use self.context...
    }
}
```

---

## Core Models

### 1. SamPerson (Identity & People)

**Purpose:** CRM overlay for a person. Apple Contacts is the system of record for identity.

```swift
@Model
public final class SamPerson {
    @Attribute(.unique) public var id: UUID
    
    // IDENTITY ANCHOR
    /// Stable CNContact.identifier (required for active people)
    public var contactIdentifier: String?
    
    // CACHED DISPLAY FIELDS (refreshed by ContactSyncService)
    public var displayNameCache: String?
    public var emailCache: String?
    public var photoThumbnailCache: Data?
    public var lastSyncedAt: Date?
    public var isArchived: Bool  // True when contact deleted externally
    
    // DEPRECATED (remove in SAM_v7)
    @deprecated("Use displayNameCache")
    public var displayName: String
    @deprecated("Use emailCache")
    public var email: String?
    
    // BUSINESS DATA
    public var roleBadges: [String]
    public var consentAlertsCount: Int
    public var reviewAlertsCount: Int
    public var responsibilityNotes: [String]
    public var recentInteractions: [InteractionChip]
    public var contextChips: [ContextChip]  // Denormalized for performance
    
    // RELATIONSHIPS
    @Relationship(deleteRule: .nullify)
    public var participations: [ContextParticipation]
    
    @Relationship(deleteRule: .nullify)
    public var responsibilitiesAsGuardian: [Responsibility]
    
    @Relationship(deleteRule: .nullify)
    public var responsibilitiesAsDependent: [Responsibility]
    
    @Relationship(deleteRule: .nullify)
    public var jointInterests: [JointInterest]
    
    @Relationship(deleteRule: .nullify)
    public var coverages: [Coverage]
    
    @Relationship(deleteRule: .nullify)
    public var consentRequirements: [ConsentRequirement]
    
    @Relationship(deleteRule: .cascade, inverse: \SamInsight.samPerson)
    public var insights: [SamInsight]
}
```

**Key Design Decisions:**

1. **Contacts-as-Identity:** `contactIdentifier` is the stable anchor. Display fields are cached for list performance but refreshed from CNContact on demand.

2. **Transitional Fields:** `displayName` and `email` are deprecated. New code should use `displayNameCache` and `emailCache`.

3. **Denormalized Data:** `contextChips` mirrors `participations` but stored flat for list rendering without loading the full graph.

### 2. SamContext (Relationship Environments)

**Purpose:** A household, business, or recruiting group.

```swift
@Model
public final class SamContext {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var kind: ContextKind  // household, business, recruitingGroup
    
    // ALERT COUNTERS (denormalized)
    public var consentAlertCount: Int
    public var reviewAlertCount: Int
    public var followUpAlertCount: Int
    
    // RELATIONSHIPS
    @Relationship(deleteRule: .cascade)
    public var participations: [ContextParticipation]
    
    @Relationship(deleteRule: .cascade)
    public var products: [Product]
    
    @Relationship(deleteRule: .cascade)
    public var consentRequirements: [ConsentRequirement]
    
    // EMBEDDED COLLECTIONS (mirrors current struct layout)
    public var productCards: [ContextProductModel]
    public var recentInteractions: [InteractionModel]
    
    @Relationship(deleteRule: .cascade, inverse: \SamInsight.samContext)
    public var insights: [SamInsight]
}
```

**Future Evolution:** `ContextKind` will expand to include:
- `personalPlanning`
- `agentTeam`
- `agentExternal`
- `referralPartner`
- `vendor`

### 3. ContextParticipation (Person ↔ Context Join)

**Purpose:** Records that a person participates in a context with a role.

```swift
@Model
public final class ContextParticipation {
    @Attribute(.unique) public var id: UUID
    
    public var person: SamPerson?
    public var context: SamContext?
    
    public var roleBadges: [String]  // e.g., ["Client", "Primary Insured"]
    public var isPrimary: Bool  // Drives sort order in detail views
    public var note: String?  // Free-text annotation
    
    public var startDate: Date
    public var endDate: Date?  // nil = ongoing
}
```

**Future Evolution:** `roleBadges` will migrate to typed `RoleType` enum once UI supports full vocabulary.

### 4. Responsibility (Guardian ↔ Dependent)

**Purpose:** Auditable link between a responsible party and a dependent.

```swift
@Model
public final class Responsibility {
    @Attribute(.unique) public var id: UUID
    
    public var guardian: SamPerson?  // Responsible party
    public var dependent: SamPerson?  // Person they're responsible for
    
    public var reason: String  // e.g., "minor", "legal guardianship"
    
    public var startDate: Date
    public var endDate: Date?
}
```

### 5. JointInterest (Shared Ownership)

**Purpose:** Group of people with joint legal/financial interest.

```swift
@Model
public final class JointInterest {
    @Attribute(.unique) public var id: UUID
    
    @Relationship(deleteRule: .nullify)
    public var members: [SamPerson]
    
    public var hasSurvivorshipRights: Bool
    public var description: String  // e.g., "Joint bank account"
}
```

### 6. Product (Insurance Products)

**Purpose:** An insurance product associated with a context.

```swift
@Model
public final class Product {
    @Attribute(.unique) public var id: UUID
    
    public var context: SamContext?
    
    public var type: ProductType  // life, health, auto, homeowners, etc.
    public var name: String
    public var subtitle: String?
    public var statusDisplay: String  // "Active", "Proposed", etc.
    public var icon: String  // SF Symbol name
    public var issuedDate: Date?
    
    @Relationship(deleteRule: .cascade)
    public var coverages: [Coverage]
    
    @Relationship(deleteRule: .cascade)
    public var consentRequirements: [ConsentRequirement]
    
    @Relationship(deleteRule: .nullify)
    public var jointInterests: [JointInterest]
}
```

### 7. Coverage (Who Is Covered)

**Purpose:** Links a person to a product with their coverage role.

```swift
@Model
public final class Coverage {
    @Attribute(.unique) public var id: UUID
    
    public var person: SamPerson?
    public var product: Product?
    
    public var role: CoverageRole  // insured, beneficiary, owner
    public var survivorshipRights: Bool
}
```

### 8. ConsentRequirement (Regulatory Compliance)

**Purpose:** Tracks consent requirements for regulatory compliance.

```swift
@Model
public final class ConsentRequirement {
    @Attribute(.unique) public var id: UUID
    
    public var person: SamPerson?
    public var context: SamContext?
    public var product: Product?
    
    public var consentType: ConsentType
    public var status: ConsentStatus
    public var dueDate: Date?
    public var completedAt: Date?
}
```

### 9. SamEvidenceItem (Intelligence Substrate)

**Purpose:** Raw facts ingested from external sources (Calendar, Mail, etc.).

```swift
@Model
public final class SamEvidenceItem {
    @Attribute(.unique) public var id: UUID
    
    /// Stable source-provided identifier for idempotent upsert
    /// Format: "eventkit:<calendarItemIdentifier>", "mail:<messageID>"
    @Attribute(.unique) public var sourceUID: String?
    
    public var source: EvidenceSource  // calendar, mail, zoom, note
    
    /// Stored as raw string to avoid SwiftData enum validation issues
    public var stateRawValue: String  // "needsReview", "done"
    
    @Transient
    public var state: EvidenceTriageState {
        get { EvidenceTriageState(rawValue: stateRawValue) ?? .needsReview }
        set { stateRawValue = newValue.rawValue }
    }
    
    // CORE FACTS
    public var occurredAt: Date
    public var title: String
    public var snippet: String
    public var bodyText: String?
    
    // COMPUTED SIGNALS (re-derived on every upsert)
    public var signals: [EvidenceSignal]
    
    // PARTICIPANT HINTS (from source event/message)
    public var participantHints: [ParticipantHint]
    
    // LINK PROPOSALS & CONFIRMATIONS
    public var proposedLinks: [ProposedLink]
    
    @Relationship(deleteRule: .nullify)
    public var linkedPeople: [SamPerson]
    
    @Relationship(deleteRule: .nullify)
    public var linkedContexts: [SamContext]
    
    @Relationship(deleteRule: .nullify, inverse: \SamInsight.basedOnEvidence)
    public var supportingInsights: [SamInsight]
}
```

**Upsert Key:** `sourceUID` enables idempotent imports. Calendar coordinator uses this to update existing evidence rather than creating duplicates.

**Pruning Strategy:** Calendar coordinator tracks the current UID set in the observed window and deletes evidence whose UIDs are no longer present (indicating the event was moved/deleted).

### 10. SamInsight (AI Recommendations)

**Purpose:** Persisted AI observations attached to person/context/product.

```swift
@Model
public final class SamInsight {
    @Attribute(.unique) public var id: UUID
    
    // ENTITY RELATIONSHIPS (what this insight is about)
    public var samPerson: SamPerson?
    public var samContext: SamContext?
    public var product: Product?
    
    // CORE PROPERTIES
    public var kind: InsightKind  // recentInteraction, familyRelationship, etc.
    public var message: String
    public var confidence: Double
    
    // SUPPORTING EVIDENCE
    @Relationship(deleteRule: .nullify, inverse: \SamEvidenceItem.supportingInsights)
    public var basedOnEvidence: [SamEvidenceItem]
    
    // LIFECYCLE
    public var createdAt: Date
    public var dismissedAt: Date?
    
    // DISPLAY HELPERS (computed from basedOnEvidence)
    public var interactionsCount: Int {
        basedOnEvidence.count
    }
    public var consentsCount: Int
}
```

**Composite Uniqueness:** InsightGenerator uses `(personID, contextID, kind)` as a grouping key to prevent duplicate insights.

**Aggregation:** Multiple evidence items with the same `(person, context, kind)` are aggregated into a single insight.

### 11. SamNote (User Notes)

**Purpose:** User-created notes about people/contexts.

```swift
@Model
public final class SamNote {
    @Attribute(.unique) public var id: UUID
    
    public var person: SamPerson?
    public var context: SamContext?
    
    public var content: String
    public var createdAt: Date
    public var modifiedAt: Date
}
```

### 12. SamAnalysisArtifact (Structured AI Output)

**Purpose:** Stores structured analysis from LLMs (extracted entities, topics, actions).

```swift
@Model
public final class SamAnalysisArtifact {
    @Attribute(.unique) public var id: UUID
    
    public var sourceNote: SamNote?
    
    // STRUCTURED EXTRACTION
    public var peopleJSON: String?  // Serialized [PersonEntity]
    public var topicsJSON: String?  // Serialized [String]
    public var actions: [String]
    
    public var usedLLM: String?  // Model identifier
    public var analyzedAt: Date
}
```

---

## Model Relationships

### Relationship Graph

```
SamPerson
    ├─→ participations: [ContextParticipation] (nullify)
    ├─→ responsibilitiesAsGuardian: [Responsibility] (nullify)
    ├─→ responsibilitiesAsDependent: [Responsibility] (nullify)
    ├─→ jointInterests: [JointInterest] (nullify)
    ├─→ coverages: [Coverage] (nullify)
    ├─→ consentRequirements: [ConsentRequirement] (nullify)
    └─→ insights: [SamInsight] (cascade, inverse)

SamContext
    ├─→ participations: [ContextParticipation] (cascade)
    ├─→ products: [Product] (cascade)
    ├─→ consentRequirements: [ConsentRequirement] (cascade)
    └─→ insights: [SamInsight] (cascade, inverse)

Product
    ├─→ coverages: [Coverage] (cascade)
    ├─→ consentRequirements: [ConsentRequirement] (cascade)
    └─→ jointInterests: [JointInterest] (nullify)

SamEvidenceItem
    ├─→ linkedPeople: [SamPerson] (nullify)
    ├─→ linkedContexts: [SamContext] (nullify)
    └─→ supportingInsights: [SamInsight] (nullify, inverse)

SamInsight
    ├─→ samPerson: SamPerson? (nullify)
    ├─→ samContext: SamContext? (nullify)
    ├─→ product: Product? (nullify)
    └─→ basedOnEvidence: [SamEvidenceItem] (nullify, inverse)
```

### Delete Rules

| Relationship | Delete Rule | Rationale |
|--------------|-------------|-----------|
| `SamPerson.insights` | `.cascade` | Insights are tied to person existence |
| `SamContext.products` | `.cascade` | Products belong to context |
| `Product.coverages` | `.cascade` | Coverage details owned by product |
| `SamEvidenceItem.linkedPeople` | `.nullify` | Evidence can exist without links |
| `SamInsight.basedOnEvidence` | `.nullify` | Evidence can exist without insights |
| `ContextParticipation.person` | `.nullify` | Participations persist if person deleted |

---

## Access Patterns

### EvidenceRepository (MainActor)

```swift
@MainActor
@Observable
final class EvidenceRepository {
    private var container: ModelContainer
    
    // QUERIES
    func needsReview() throws -> [SamEvidenceItem] {
        let ctx = ModelContext(container)
        let predicate = #Predicate<SamEvidenceItem> {
            $0.stateRawValue == "needsReview"
        }
        let descriptor = FetchDescriptor<SamEvidenceItem>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
        )
        return try ctx.fetch(descriptor)
    }
    
    // MUTATIONS
    func upsert(_ newItem: SamEvidenceItem) throws {
        let ctx = ModelContext(container)
        if let uid = newItem.sourceUID {
            // Try to find existing by sourceUID
            let fetch = FetchDescriptor<SamEvidenceItem>(
                predicate: #Predicate { $0.sourceUID == uid }
            )
            if let existing = try ctx.fetch(fetch).first {
                // Update existing
                existing.title = newItem.title
                // ... update other fields
                try ctx.save()
                return
            }
        }
        // Insert new
        ctx.insert(newItem)
        try ctx.save()
    }
    
    // PRUNING
    func pruneCalendarEvidenceNotIn(_ currentUIDs: Set<String>, windowStart: Date, windowEnd: Date) {
        let ctx = ModelContext(container)
        let fetch = FetchDescriptor<SamEvidenceItem>(
            predicate: #Predicate {
                $0.occurredAt >= windowStart &&
                $0.occurredAt <= windowEnd
            }
        )
        guard let items = try? ctx.fetch(fetch) else { return }
        for item in items where item.source == .calendar {
            if let uid = item.sourceUID, !currentUIDs.contains(uid) {
                ctx.delete(item)
            }
        }
        try? ctx.save()
    }
}
```

### InsightGenerator (Actor)

```swift
actor InsightGenerator {
    private let context: ModelContext
    
    init(context: ModelContext) {
        self.context = context
    }
    
    func generatePendingInsights() async {
        // Fetch evidence with signals
        let fetch = FetchDescriptor<SamEvidenceItem>()
        let evidence = (try? context.fetch(fetch)) ?? []
        let withSignals = evidence.filter { !$0.signals.isEmpty }
        
        // Group by (person, context, kind)
        var groups: [InsightGroupKey: [SamEvidenceItem]] = [:]
        for item in withSignals {
            let person = item.linkedPeople.first
            let context = item.linkedContexts.first
            for signal in item.signals {
                let kind = insightKind(for: signal.kind)
                let key = InsightGroupKey(personID: person?.id, contextID: context?.id, kind: kind)
                groups[key, default: []].append(item)
            }
        }
        
        // Upsert insights
        for (key, items) in groups {
            if let existing = findInsight(person: key.personID, context: key.contextID, kind: key.kind) {
                // Merge evidence
                let newItems = items.filter { !existing.basedOnEvidence.contains($0) }
                existing.basedOnEvidence.append(contentsOf: newItems)
            } else {
                // Create new
                let insight = SamInsight(kind: key.kind, message: "...", basedOnEvidence: items)
                context.insert(insight)
            }
        }
        
        try? context.save()
    }
}
```

### ContactSyncService (Observable, per-call context)

```swift
public final class ContactSyncService: Observable {
    private let store: CNContactStore
    
    public func contact(for person: SamPerson) throws -> CNContact? {
        guard let identifier = person.contactIdentifier else { return nil }
        return try store.unifiedContact(withIdentifier: identifier, keysToFetch: Self.allContactKeys)
    }
    
    public func refreshCache(for person: SamPerson, context: ModelContext) throws {
        guard let contact = try contact(for: person) else { return }
        
        person.displayNameCache = CNContactFormatter.string(from: contact, style: .fullName)
        person.emailCache = contact.emailAddresses.first.map { String($0.value) }
        person.photoThumbnailCache = contact.thumbnailImageData
        person.lastSyncedAt = Date()
        
        try context.save()
    }
}
```

---

## Concurrency Considerations

### Thread Safety Rules

1. **One ModelContext per actor** - Never share a ModelContext across actors
2. **Models don't cross actors** - Models fetched on one actor stay on that actor
3. **Pass IDs, not models** - Use `UUID` or value types for cross-actor communication
4. **Value types for communication** - Structs/enums are Sendable

### Example: Safe Cross-Actor Communication

```swift
// ✅ CORRECT: Pass IDs
@MainActor
func getEvidenceIDs() throws -> [UUID] {
    let ctx = ModelContext(SAMModelContainer.shared)
    let items = try ctx.fetch(FetchDescriptor<SamEvidenceItem>())
    return items.map(\.id)
}

actor Processor {
    private let context: ModelContext
    
    init() {
        self.context = ModelContext(SAMModelContainer.shared)
    }
    
    func process(evidenceIDs: [UUID]) async throws {
        for id in evidenceIDs {
            let descriptor = FetchDescriptor<SamEvidenceItem>(
                predicate: #Predicate { $0.id == id }
            )
            if let item = try context.fetch(descriptor).first {
                // Process item on this actor
                item.state = .done
            }
        }
        try context.save()
    }
}

// Usage:
@MainActor
func doWork() async throws {
    let ids = try getEvidenceIDs()
    await Processor().process(evidenceIDs: ids)
}
```

### Example: Value Type DTO

```swift
struct PersonSummary: Sendable {
    let id: UUID
    let name: String
    let email: String?
    let contextCount: Int
}

@MainActor
func getPeopleSummaries() throws -> [PersonSummary] {
    let ctx = ModelContext(SAMModelContainer.shared)
    let people = try ctx.fetch(FetchDescriptor<SamPerson>())
    return people.map { person in
        PersonSummary(
            id: person.id,
            name: person.displayNameCache ?? person.displayName,
            email: person.emailCache ?? person.email,
            contextCount: person.participations.count
        )
    }
}

actor Reporter {
    func generate(_ summaries: [PersonSummary]) async {
        for summary in summaries {
            print("\(summary.name): \(summary.contextCount) contexts")
        }
    }
}
```

---

## Migration Notes

### v5 → v6

**Added:**
- `SamNote` model
- `SamAnalysisArtifact` model
- Structured entity storage fields (`peopleJSON`, `topicsJSON`, `actions`)
- LLM tracking (`usedLLM`)

**Changed:**
- `SamPerson`: Added cache fields (`displayNameCache`, `emailCache`, `photoThumbnailCache`, `lastSyncedAt`, `isArchived`)
- `SamPerson`: Deprecated `displayName` and `email` (use cache variants)

**Migration Strategy:**
1. Copy `displayName` → `displayNameCache`
2. Copy `email` → `emailCache`
3. Set `lastSyncedAt` to nil (will refresh on next sync)
4. Keep deprecated fields until v7 for backward compatibility

### Future v6 → v7

**Planned Changes:**
- Remove deprecated `displayName` and `email` from `SamPerson`
- All code must use `displayNameCache` and `emailCache`
- Normalize `roleBadges` to typed `RoleType` enum
- Expand `ContextKind` to full vocabulary

---

## Summary

### Quick Reference Table

| Model | Purpose | Key Relationships | Delete Rule |
|-------|---------|-------------------|-------------|
| `SamPerson` | Identity layer | participations, coverages, insights | cascade insights |
| `SamContext` | Relationship groups | participations, products | cascade children |
| `ContextParticipation` | Person-Context join | person, context | nullify |
| `Product` | Insurance products | coverages, consents | cascade children |
| `SamEvidenceItem` | Raw intelligence | linkedPeople, insights | nullify |
| `SamInsight` | AI recommendations | person, context, evidence | nullify links |
| `SamNote` | User notes | person, context | - |
| `SamAnalysisArtifact` | Structured AI output | note | - |

### Key Takeaways

1. **Contacts-as-Identity:** `SamPerson.contactIdentifier` is the anchor; display fields are cached
2. **Upsert by sourceUID:** Evidence uses `sourceUID` for idempotent imports
3. **Composite uniqueness:** Insights grouped by `(person, context, kind)`
4. **Denormalized counts:** Alert counts stored on models for list performance
5. **Inverse relationships:** SwiftData manages bidirectional links automatically
6. **RawValue enums:** `stateRawValue` avoids SwiftData enum validation issues
7. **Actor isolation:** Each actor creates its own ModelContext
8. **Value type communication:** Pass IDs/structs between actors, not model objects

---

**End of Data Model Architecture Document**
