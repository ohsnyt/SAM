# SAM — Project Context
**Platform**: macOS  
**Language**: Swift 6  
**Architecture**: Clean layered architecture with strict separation of concerns  
**Framework**: SwiftUI + SwiftData  
**Last Updated**: February 11, 2026 (Phase I complete — Insights & Awareness)

**Related Docs**: 
- See `agent.md` for product philosophy and UX principles
- See `changelog.md` for historical completion notes

---

## 1. Project Overview

### Purpose

SAM is a **native macOS relationship management application** for independent financial strategists. It observes interactions from Apple's Calendar and Contacts, transforms them into Evidence, and generates AI-backed Insights to help advisors stay aware of client life events and opportunities.

**Core Philosophy**:
- Apple Contacts and Calendar are the **systems of record** for identity and events
- SAM is an **overlay CRM** that enhances but never replaces Apple's data
- AI assists but **never acts autonomously** — all actions require user review
- **Clean architecture** with explicit boundaries between layers

### Target Platform

- **macOS only** (not iOS, not cross-platform)
- Requires macOS 14+ (for Swift 6 and modern SwiftData features)
- Native SwiftUI interface following macOS design patterns
- Supports keyboard shortcuts and menu bar commands

---

## 2. Architecture Principles

### Clean Layered Architecture

```
┌─────────────────────────────────────────────────────┐
│                    Views (SwiftUI)                  │
│          PeopleListView, PersonDetailView, etc.     │
└──────────────────────┬──────────────────────────────┘
                       │ Uses DTOs
                       ▼
┌─────────────────────────────────────────────────────┐
│                   Coordinators                      │
│     ContactsImportCoordinator, InsightGenerator     │
│            (Business Logic Orchestration)           │
└───────────┬─────────────────────┬───────────────────┘
            │                     │
            │ Reads from          │ Writes to
            ▼                     ▼
┌──────────────────────┐  ┌──────────────────────────┐
│      Services        │  │     Repositories         │
│  ContactsService     │  │   PeopleRepository       │
│  (External APIs)     │  │   (SwiftData CRUD)       │
└──────────────────────┘  └──────────────────────────┘
            │                     │
            │ Returns DTOs        │ Stores Models
            ▼                     ▼
┌──────────────────────┐  ┌──────────────────────────┐
│   External APIs      │  │      SwiftData           │
│ CNContactStore       │  │   SamPerson, SamContext  │
│ EKEventStore         │  │   SamEvidenceItem, etc.  │
└──────────────────────┘  └──────────────────────────┘
```

### Layer Responsibilities

**Views (SwiftUI)**:
- Render UI and handle user interaction
- Use DTOs (never raw CNContact/EKEvent)
- Observe coordinators and repositories
- `@MainActor` implicit

**Coordinators**:
- Orchestrate business logic (e.g., import flows, insight generation)
- Coordinate between services and repositories
- Manage debouncing, throttling, and state machines
- `@MainActor` when needed for SwiftUI observation
- **Follow standard API pattern** (see §2.4 Coordinator API Standards below)

**Services**:
- Own external API access (CNContactStore, EKEventStore)
- Return only Sendable DTOs (never CNContact/EKEvent directly)
- Check authorization before all data access
- Actor-isolated for thread safety

**Repositories**:
- CRUD operations for SwiftData models
- No external API access (only SwiftData)
- Receive DTOs from coordinators
- `@MainActor` isolated (SwiftData requirement)

**DTOs (Data Transfer Objects)**:
- Sendable structs that wrap external data
- Can cross actor boundaries safely
- Used for communication between layers

### Coordinator API Standards

**The Pattern**: All coordinators handling similar operations (import, sync, background tasks) should expose **consistent, predictable APIs** to reduce cognitive load and enable code reuse.

**Standard Import Coordinator API** (Phases C & E):

```swift
@MainActor
@Observable
final class XYZImportCoordinator {
    
    // MARK: - Observable State (for UI binding)
    
    /// Current import status (enum for type safety)
    var importStatus: ImportStatus = .idle
    
    /// Timestamp of last successful import
    var lastImportedAt: Date?
    
    /// Count of items imported in last operation
    var lastImportCount: Int = 0
    
    /// Error message if import failed
    var lastError: String?
    
    // MARK: - Settings (UserDefaults-backed, @ObservationIgnored)
    
    @ObservationIgnored
    var autoImportEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "xyz.autoImportEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "xyz.autoImportEnabled") }
    }
    
    // MARK: - Public API
    
    /// Manual import (user-initiated, async)
    func importNow() async { ... }
    
    /// Auto import (system-initiated)
    func startAutoImport() { 
        Task { await importNow() }
    }
    
    /// Request authorization (Settings-only)
    func requestAuthorization() async -> Bool { ... }
    
    // MARK: - Status Enum
    
    enum ImportStatus: Equatable {
        case idle
        case importing
        case success
        case failed
        
        var displayText: String {
            switch self {
            case .idle: return "Ready"
            case .importing: return "Importing..."
            case .success: return "Synced"
            case .failed: return "Failed"
            }
        }
    }
}
```

**Benefits of Standardization**:
- ✅ **Predictable** - All coordinators have same API surface
- ✅ **Copy-paste safe** - Settings views can be templated
- ✅ **Type-safe** - Enum-based status reduces errors vs Bools
- ✅ **Observable** - All UI-visible state is marked for observation
- ✅ **Testable** - Can write shared test utilities

**Current Status (February 10, 2026)**:
- ✅ **CalendarImportCoordinator** - Follows standard pattern (Phase E)
- ⚠️ **ContactsImportCoordinator** - Uses older pattern (Phase C, predates standard)
  - Uses `isImporting: Bool` instead of `importStatus: ImportStatus`
  - Uses `lastImportResult: ImportResult?` instead of `lastImportedAt: Date?`
  - **To be refactored** in Phase F or I for consistency

**Migration Note**: When refactoring ContactsImportCoordinator, add new properties alongside old ones temporarily, then migrate all call sites before removing deprecated properties.

---

## 3. Project Structure

```
SAM_crm/SAM_crm/
├── App/
│   ├── SAMApp.swift                    ✅ Complete - App entry point
│   └── SAMModelContainer.swift         ✅ Complete - SwiftData container
│
├── Services/                           
│   ├── ContactsService.swift           ✅ Phase B - All CNContact operations
│   ├── CalendarService.swift           ⬜ Phase E - All EKEvent operations
│   └── MessagingService.swift          ⬜ Phase L - iMessage/FaceTime (if APIs available)
│
├── Coordinators/                       
│   ├── ContactsImportCoordinator.swift ✅ Phase C - Orchestrates contact import
│   ├── CalendarImportCoordinator.swift ⬜ Phase E - Orchestrates calendar import
│   ├── MessagingImportCoordinator.swift ⬜ Phase L - Orchestrates message/call import
│   ├── InsightGenerator.swift          ⬜ Phase H - Generate insights
│   └── UndoCoordinator.swift           ⬜ Phase M - Universal undo system
│
├── Repositories/                       
│   ├── PeopleRepository.swift          ✅ Phase C - CRUD for SamPerson
│   ├── EvidenceRepository.swift        🟡 Partial - CRUD for SamEvidenceItem
│   ├── ContextsRepository.swift        ⬜ Phase G - CRUD for SamContext
│   ├── NotesRepository.swift           ⬜ Phase J - CRUD for SamNote
│   ├── TimeTrackingRepository.swift    ⬜ Phase K - CRUD for TimeEntry
│   └── UndoRepository.swift            ⬜ Phase M - CRUD for UndoEntry
│
├── Models/
│   ├── SwiftData/
│   │   └── SAMModels.swift             ✅ Complete - @Model classes
│   │       ├── SamPerson
│   │       ├── SamEvidenceItem
│   │       ├── SamContext
│   │       ├── SamInsight
│   │       ├── SamNote (Phase J)
│   │       ├── TimeEntry (Phase K)
│   │       └── UndoEntry (Phase M)
│   │
│   └── DTOs/                           
│       ├── ContactDTO.swift            ✅ Phase B - Sendable CNContact wrapper
│       ├── EventDTO.swift              ⬜ Phase E - Sendable EKEvent wrapper
│       └── MessageDTO.swift            ⬜ Phase L - Sendable message wrapper
│
├── Views/
│   ├── AppShellView.swift              ✅ Phase D - Main navigation container
│   │
│   ├── People/
│   │   ├── PeopleListView.swift        ✅ Phase D - List of people
│   │   ├── PersonDetailView.swift      ✅ Phase D - Person detail
│   │   └── NoteEditorView.swift        ⬜ Phase J - Add/edit notes
│   │
│   ├── Inbox/
│   │   ├── InboxListView.swift         ⬜ Phase F - Evidence list
│   │   └── InboxDetailView.swift       ⬜ Phase F - Evidence detail
│   │
│   ├── Contexts/
│   │   ├── ContextListView.swift       ⬜ Phase G - Context list
│   │   └── ContextDetailView.swift     ⬜ Phase G - Context detail
│   │
│   ├── Awareness/
│   │   └── AwarenessView.swift         ⬜ Phase H - Insights dashboard
│   │
│   ├── TimeTracking/
│   │   ├── TimeTrackingView.swift      ⬜ Phase K - Time entry management
│   │   └── TimeReportsView.swift       ⬜ Phase K - Time analysis/reports
│   │
│   ├── Undo/
│   │   └── UndoHistoryView.swift       ⬜ Phase M - Undo history browser
│   │
│   └── Settings/
│       ├── SettingsView.swift          🟡 Partial - App settings
│       ├── PermissionsSettingsView.swift ⬜ Phase I - Permission management
│       ├── AIPromptSettingsView.swift  ⬜ Phase I - Customize AI prompts
│       └── MeContactSettingsView.swift ⬜ Phase J - Select "Me" contact
│
└── Utilities/
    └── PermissionsManager.swift        ✅ Phase B - Centralized auth
```

**Legend**:
- ✅ Complete and following clean architecture
- 🟡 Partial or needs refactoring
- ⬜ Not yet implemented

---

## 4. Data Models

### Identity Strategy (Contacts-First)

**Apple Contacts = System of Record**:
- All identity data (names, family relationships, contact info, dates) lives in Apple Contacts
- SAM stores only `contactIdentifier` as anchor + cached display fields
- Family relationships read from `CNContact.contactRelations` (not duplicated)
- Contact info (phone, email, address) lazy-loaded in detail views

**SamPerson Model**:
```swift
@Model
final class SamPerson {
    // Anchor
    var contactIdentifier: String?      // CNContact.identifier (stable ID)
    
    // Cached display fields (refreshed on sync)
    var displayNameCache: String?       // For list performance
    var emailCache: String?
    var photoThumbnailCache: Data?
    var lastSyncedAt: Date?
    var isArchived: Bool                // Contact deleted externally
    
    // SAM-owned data
    var isMe: Bool                      // True if this is the user's own contact (Phase J)
    var roleBadges: [String]            // "Client", "Referral Partner", etc.
    var consentAlertsCount: Int
    var reviewAlertsCount: Int
    
    // Relationships (SAM-owned)
    var participations: [ContextParticipation]
    var coverages: [Coverage]
    var insights: [SamInsight]
    var notes: [SamNote]                // User-created notes (Phase J)
}
```

### Other Models

**SamContext**: Households, businesses, or groups of people
```swift
@Model
final class SamContext {
    var displayName: String
    var contextType: String             // "Household", "Business"
    var participations: [ContextParticipation]
    var coverages: [Coverage]
}
```

**SamEvidenceItem**: Observations from Calendar/Contacts/Notes/Messages
```swift
@Model
final class SamEvidenceItem {
    var title: String
    var evidenceType: String            // "CalendarEvent", "ContactUpdate", "UserNote", "iMessage", "FaceTime", etc.
    var sourceIdentifier: String?       // EKEvent.eventIdentifier, CNContact.identifier, or nil for user notes
    var rawContent: String?             // Only for user notes (no external source)
    var observedAt: Date
    var triageState: String             // "needsReview", "reviewed", "dismissed"
    var attachedPeople: [SamPerson]
    var relatedContext: SamContext?
}
```

**SamNote**: User-created notes (Phase J)
```swift
@Model
final class SamNote {
    var content: String                 // Raw note text (user-entered)
    var createdAt: Date
    var updatedAt: Date
    var relatedPerson: SamPerson?
    var relatedContext: SamContext?
    var linkedEvidence: SamEvidenceItem? // Note becomes evidence for AI analysis
}
```

**TimeEntry**: Time tracking (Phase K)
```swift
@Model
final class TimeEntry {
    var startTime: Date
    var endTime: Date?
    var activityType: String            // "ClientMeeting", "Preparation", "VendorCall", etc.
    var relatedPerson: SamPerson?
    var relatedContext: SamContext?
    var notes: String?
    var calendarEventIdentifier: String? // Link to calendar event if applicable
}
```

**UndoEntry**: Universal undo system (Phase M)
```swift
@Model
final class UndoEntry {
    var timestamp: Date
    var operationType: String           // "delete", "update", "create"
    var modelType: String               // "SamPerson", "SamContext", etc.
    var modelIdentifier: String
    var beforeState: Data               // JSON snapshot before change
    var afterState: Data?               // JSON snapshot after change (nil for creates)
    var expiresAt: Date                 // Auto-delete after 30 days
}
```

**SamInsight**: AI-generated insights
```swift
@Model
final class SamInsight {
    var title: String
    var body: String
    var insightType: String
    var samPerson: SamPerson?
    var createdAt: Date
}
```

### Property Naming Conventions

To maintain consistency across the codebase and prevent compile errors, follow these naming conventions:

**Core Principles**:
- Use simple property names for stable identifiers (e.g., `name`, not `displayName`)
- Use typed enums instead of string properties where appropriate
- Cache properties must end with `Cache` suffix to indicate synced data
- Deprecated properties should be marked with comments

**Examples**:

```swift
// ✅ CORRECT - Simple identifier
@Model
final class SamContext {
    var name: String              // Simple, stable identifier
    var kind: ContextKind         // Typed enum (not String)
}

// ✅ CORRECT - Cache vs source distinction
@Model
final class SamPerson {
    var displayName: String       // DEPRECATED - transitional field
    var displayNameCache: String? // Refreshed from CNContact
    var emailCache: String?       // Refreshed from CNContact
}

// ❌ INCORRECT - Mixed naming
@Model
final class SamContext {
    var displayName: String       // Wrong - should be 'name'
    var contextType: String       // Wrong - should be typed enum 'kind'
}
```

**Benefits**:
- **Type safety**: Enums prevent string typos (e.g., `kind.rawValue` vs hardcoded strings)
- **Clear semantics**: Cache properties indicate synced external data
- **Consistency**: All models follow same patterns
- **Compile-time checks**: Views must use correct property names

**In Views**:
```swift
// ✅ CORRECT
Text(context.name)              // Simple property
Text(context.kind.rawValue)     // Enum raw value for display
Text(person.displayNameCache ?? person.displayName) // Cache fallback

// ❌ INCORRECT
Text(context.displayName)       // Compile error - property doesn't exist
Text(context.contextType)       // Compile error - property doesn't exist
```

---

## 5. Phase Status & Roadmap

**Note**: Completed phases documented in `changelog.md`. This section focuses on current and future work.

### Current Status

**Completed Phases** (see `changelog.md` for details):
- ✅ **Phase A**: Foundation (app structure, models, container)
- ✅ **Phase B**: Services Layer (ContactsService, ContactDTO, PermissionsManager)
- ✅ **Phase C**: Data Layer (PeopleRepository, ContactsImportCoordinator)
- ✅ **Phase D**: First Feature - People (PeopleListView, PersonDetailView)

**Next Up**:
- ⬜ **Phase E**: Calendar & Evidence
- ⬜ **Phase F**: Inbox (triage evidence)
- ⬜ **Phase G**: Contexts (households/businesses)
- ⬜ **Phase H**: Insights (AI-generated)
- ⬜ **Phase I**: Settings & Polish
- ⬜ **Phase J**: "Me" Contact & User Notes
- ⬜ **Phase K**: Time Tracking
- ⬜ **Phase L**: iMessage & FaceTime Evidence (if APIs available)
- ⬜ **Phase M**: Universal Undo System

---

### ⬜ Phase E: Calendar & Evidence (NOT STARTED)

**Goal**: Calendar events create Evidence items

**Tasks**:
- ⬜ Create CalendarService.swift (actor-based, similar to ContactsService)
- ⬜ Create EventDTO.swift (Sendable EKEvent wrapper)
- ⬜ Complete EvidenceRepository.swift
- ⬜ Create CalendarImportCoordinator.swift
- ⬜ Wire up calendar permission flow

**Expected Outcome**: Events from SAM calendar appear as Evidence

---

### ⬜ Phase F: Inbox (NOT STARTED)

**Goal**: View and triage evidence

**Tasks**:
- ⬜ Create InboxListView.swift
- ⬜ Create InboxDetailView.swift
- ⬜ Add triage actions (review, dismiss, etc.)

**Expected Outcome**: Can see evidence items, mark as reviewed

---

### ⬜ Phase G: Contexts (NOT STARTED)

**Goal**: Manage households and business contexts

**Tasks**:
- ⬜ Create ContextsRepository.swift
- ⬜ Create ContextListView.swift
- ⬜ Create ContextDetailView.swift
- ⬜ Add context creation/editing

**Expected Outcome**: Can create household/business contexts

---

### ⬜ Phase H: Insights (NOT STARTED)

**Goal**: AI-generated insights appear in UI

**Tasks**:
- ⬜ Create InsightGenerator.swift coordinator
- ⬜ Create AwarenessView.swift
- ⬜ Wire up insight generation after imports
- ⬜ Display insights in awareness tab

**Expected Outcome**: Insights appear in Awareness tab

---

### ⬜ Phase I: Settings & Polish (NOT STARTED)

**Goal**: Complete settings UI and polish

**Tasks**:
- ⬜ Complete SettingsView.swift
- ⬜ Add permission management UI
- ⬜ Add calendar/contact group selection
- ⬜ Add AI prompt customization UI
- ⬜ Add keyboard shortcuts
- ⬜ Polish UI animations and transitions

**Expected Outcome**: All settings functional, polished UX

---

### ⬜ Phase J: "Me" Contact & User Notes (NOT STARTED)

**Goal**: Identify user's own contact and add user-initiated notes

**Tasks**:
- ⬜ Add "Me" contact identification
  - Add `isMe: Bool` field to SamPerson model
  - Add method to PeopleRepository to find/set "Me" contact
  - Add UI in Settings to select "Me" contact (defaults to CNContactStore.defaultContainerIdentifier's "Me" card)
- ⬜ Implement user notes feature
  - SamNote already exists in models (stores raw note text)
  - Create NotesRepository.swift for CRUD operations
  - Add "Add Note" button to PersonDetailView
  - Create NoteEditorView.swift (sheet for note entry)
  - Store raw note text (no external source to link to)
  - Notes become Evidence items with evidenceType: "UserNote"
  - Link notes to specific people or contexts

**Expected Outcome**: 
- User can identify themselves in the system
- User can add freeform notes that SAM can analyze for insights

**Architecture Notes**:
- User notes have no external sourceIdentifier (SAM-native data)
- Raw text stored in SamNote, analysis stored in linked SamEvidenceItem
- Notes can trigger AI analysis for relationship insights

**Data Model Relationship Pattern**:

The notes relationship is **unidirectional** (notes → people), not bidirectional:

```swift
// SamNote has relationship TO people (many-to-many)
@Model
final class SamNote {
    @Relationship(deleteRule: .nullify)
    var linkedPeople: [SamPerson] = []
    
    @Relationship(deleteRule: .nullify)
    var linkedContexts: [SamContext] = []
}

// SamPerson does NOT have inverse 'notes' property
// Notes are queried, not navigated via relationship
@Model
final class SamPerson {
    // No 'var notes: [SamNote]' property
    // Instead, query notes where linkedPeople contains this person
}
```

**Why no inverse relationship?**
- Notes can link to **multiple people** (many-to-many)
- Query-based access keeps data model flexible
- Avoids inverse relationship maintenance overhead
- Allows notes without people (general journal entries)

**Querying Notes for a Person** (Three approaches):

```swift
// Approach 1: SwiftUI @Query with filter
@Query(filter: #Predicate<SamNote> { note in
    note.linkedPeople.contains(where: { $0.id == person.id })
})
var notesForPerson: [SamNote]

// Approach 2: Repository method with fetch-all + filter
func fetchNotes(forPerson person: SamPerson) throws -> [SamNote] {
    let descriptor = FetchDescriptor<SamNote>()
    let allNotes = try context.fetch(descriptor)
    return allNotes.filter { note in
        note.linkedPeople.contains(where: { $0.id == person.id })
    }
}

// Approach 3: Direct ModelContext query
let descriptor = FetchDescriptor<SamNote>(
    sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
)
let allNotes = try context.fetch(descriptor)
let personNotes = allNotes.filter { $0.linkedPeople.contains(where: { $0.id == person.id }) }
```

**Implementation Recommendation**:
Use Approach 2 (repository method) for consistency with clean architecture. Views call `NotesRepository.fetchNotes(forPerson:)` rather than directly querying SwiftData.

**Performance Note**:
Fetch-all + filter is acceptable for typical note counts (< 10,000). If performance becomes an issue, consider:
- Adding computed property to cache note count on SamPerson
- Implementing inverse relationship with manual maintenance
- Using Core Data batch fetch predicates (future optimization)

---

### ⬜ Phase K: Time Tracking (NOT STARTED)

**Goal**: Allow user to document time spent on activities

**Tasks**:
- ⬜ Create TimeEntry model
  ```swift
  @Model
  final class TimeEntry {
      var startTime: Date
      var endTime: Date?
      var activityType: String  // "ClientMeeting", "Preparation", "VendorCall", etc.
      var relatedPerson: SamPerson?
      var relatedContext: SamContext?
      var notes: String?
  }
  ```
- ⬜ Create TimeTrackingRepository.swift
- ⬜ Add time tracking UI
  - Quick "Start Timer" button in menu bar or toolbar
  - TimeTrackingView.swift for managing entries
  - Category selection (client work, admin, prospecting, etc.)
- ⬜ Generate time reports
  - Time spent by person
  - Time spent by activity type
  - Time spent by context (household/business)
- ⬜ Optional: Calendar integration
  - Suggest calendar event color coding based on time entries
  - (Requires permission to write to calendar)

**Expected Outcome**: User can track and reflect on how time is spent

**Architecture Notes**:
- TimeEntry is SAM-native (no external source)
- Can link to calendar events via sourceIdentifier
- Enables "how did I spend my week?" insights

---

### ⬜ Phase L: iMessage & FaceTime Evidence (NOT STARTED)

**Goal**: Observe iMessage and FaceTime interactions as evidence

**Tasks**:
- ⬜ Research macOS APIs for iMessage/FaceTime access
  - Investigate if public APIs exist (likely not)
  - Consider SQLite database access (iMessage database)
  - Consider alternative: Zoom/Teams integration instead
- ⬜ Create MessagingService.swift (if APIs available)
  - Similar pattern to ContactsService
  - Returns MessageDTO (Sendable wrapper)
  - Checks authorization before access
- ⬜ Create MessageImportCoordinator.swift
  - Fetches messages/calls
  - Creates Evidence items
  - Links to existing SamPerson by phone/email
- ⬜ Add messaging evidence to Inbox
  - Evidence type: "iMessage", "FaceTime", "ZoomCall"
  - Display message metadata (not full body)
  - AI analysis generates insights

**Expected Outcome**: Communication history appears as Evidence

**Architecture Notes**:
- High risk: No public APIs for iMessage/FaceTime
- Alternative: Focus on Zoom/Teams/Slack where APIs exist
- Privacy-first: Store metadata + analysis, not raw messages
- May require external integrations (webhooks, APIs)

**Decision Point**: Research API availability before committing to this phase

---

### ⬜ Phase M: Universal Undo System (NOT STARTED)

**Goal**: 30-day undo history for all destructive operations

**Tasks**:
- ⬜ Design undo architecture
  - Create UndoEntry model (captures before/after state)
  - Create UndoManager coordinator (not NSUndoManager)
  - Store snapshots of changed objects
- ⬜ Implement UndoRepository.swift
  - Store undo entries with 30-day expiration
  - Capture operation type, timestamp, affected models
  - Store serialized "before" state (JSON)
- ⬜ Add undo hooks to all repositories
  - PeopleRepository: Capture before delete/update
  - EvidenceRepository: Capture before triage changes
  - ContextsRepository: Capture before context changes
- ⬜ Create UndoHistoryView.swift
  - List recent operations
  - Preview before/after states
  - "Undo" button restores previous state
- ⬜ Add automatic cleanup
  - Background task removes entries > 30 days old
  - Optional: Compress old entries for archival

**Expected Outcome**: User can undo any destructive action within 30 days

**Architecture Notes**:
- Undo != NSUndoManager (incompatible with SwiftData)
- Store snapshots as JSON (Codable)
- Repository pattern: all mutations go through repositories, so easy to intercept
- Undo coordinator observes repository mutations, captures state

**Implementation Strategy**:
```swift
protocol Undoable {
    func captureState() throws -> Data  // Serialize to JSON
    func restoreState(_ data: Data) throws
}

@Model
final class UndoEntry {
    var timestamp: Date
    var operationType: String  // "delete", "update", "create"
    var modelType: String      // "SamPerson", "SamContext"
    var modelIdentifier: String
    var beforeState: Data      // JSON snapshot
    var afterState: Data?      // Optional for creates
}
```

---

## 6. Critical Patterns & Gotchas

### 6.1 Permissions (NEVER TRIGGER SURPRISE DIALOGS)

**The Rule**: Always check authorization BEFORE accessing data

```swift
// ✅ SAFE - Check before access
guard await contactsService.authorizationStatus() == .authorized else {
    return nil
}
let contact = await contactsService.fetchContact(identifier: id, keys: .minimal)

// ❌ UNSAFE - Will trigger dialog if not authorized
let store = CNContactStore()
let contact = try store.unifiedContact(withIdentifier: id, keysToFetch: [])
```

**Best Practices**:
1. Use shared store instances (ContactsService, PermissionsManager)
2. Check authorization status before every data access
3. Keep permission requests in Settings (user-initiated)
4. Never create new CNContactStore/EKEventStore instances in views
5. Background coordinators check status, never request

**Affected Components**:
- ContactsService: Checks auth in every method
- ContactsImportCoordinator: Checks auth before import
- PermissionsManager: Centralized permission requests
- Views: Never directly access CNContact/EKEvent

---

### 6.2 Concurrency (Swift 6 Strict Mode)

**Actor Isolation Rules**:

```swift
// Services: Use `actor`
actor ContactsService {
    func fetchContact(...) async -> ContactDTO? { ... }
}

// Coordinators: Use `@MainActor` only if needed for SwiftUI
@MainActor
@Observable
final class ContactsImportCoordinator {
    func importNow() async { ... }
}

// Repositories: Must be `@MainActor` (SwiftData requirement)
@MainActor
@Observable
final class PeopleRepository {
    func upsert(contact: ContactDTO) throws { ... }
}

// Views: Implicitly `@MainActor`
struct PersonDetailView: View {
    var body: some View { ... }
}
```

**Sendable Requirements**:
- All data crossing actor boundaries must be `Sendable`
- DTOs are Sendable structs (ContactDTO, EventDTO)
- Never pass CNContact/EKEvent across boundaries
- SwiftData models are NOT Sendable (MainActor-isolated only)

---

### 6.3 @Observable + Property Wrappers (Known Issue)

**Problem**: `@Observable` macro conflicts with property wrappers like `@AppStorage`

```swift
// ❌ BROKEN - Synthesized backing storage collision
@MainActor
@Observable
final class Coordinator {
    @AppStorage("key") var setting: Bool = true  // Error: duplicate _setting
}
```

**Solution**: Use computed properties with manual UserDefaults access + `@ObservationIgnored`

```swift
// ✅ WORKS - Manual UserDefaults access with @ObservationIgnored
@MainActor
@Observable
final class Coordinator {
    @ObservationIgnored
    var setting: Bool {
        get { UserDefaults.standard.bool(forKey: "key") }
        set { UserDefaults.standard.set(newValue, forKey: "key") }
    }
}
```

**Affected Files**:
- ContactsImportCoordinator.swift (uses @ObservationIgnored for UserDefaults properties)
- Any future coordinators with persisted settings

---

### 6.4 SwiftData Best Practices

**Enum Storage** (Common Gotcha):
Never store enums directly - SwiftData schema validation fails

```swift
// ❌ BROKEN - Schema validation error
@Model
final class Evidence {
    var state: EvidenceState  // Error: "rawValue is not a member"
}

// ✅ WORKS - Store raw value + computed property
@Model
final class Evidence {
    var stateRawValue: String
    
    @Transient var state: EvidenceState {
        get { EvidenceState(rawValue: stateRawValue) ?? .needsReview }
        set { stateRawValue = newValue.rawValue }
    }
}
```

**Model Initialization**:
Always use the full initializer with all required parameters

```swift
// ❌ BROKEN - Missing required parameters
let person = SamPerson(
    contactIdentifier: "123",
    displayName: "John Doe"
)

// ✅ WORKS - All required parameters provided
let person = SamPerson(
    id: UUID(),
    displayName: "John Doe",
    roleBadges: [],
    contactIdentifier: "123",
    email: "john@example.com"
)
```

**Search/Filtering with Predicates**:
Swift 6 predicates can't capture outer scope variables. Use fetch-all + in-memory filter for simple searches.

```swift
// ❌ BROKEN - Can't capture lowercaseQuery
let descriptor = FetchDescriptor<SamPerson>(
    predicate: #Predicate { person in
        person.displayName.contains(lowercaseQuery)  // Error: can't capture
    }
)

// ✅ WORKS - Fetch all, filter in memory
let allPeople = try context.fetch(FetchDescriptor<SamPerson>())
let filtered = allPeople.filter { person in
    person.displayName.lowercased().contains(query.lowercased())
}
```

**Container Configuration**:
- Use singleton pattern: `SAMModelContainer.shared`
- Configure repositories at app launch: `PeopleRepository.shared.configure(container:)`
- Never create multiple ModelContainers
- Use `nonisolated` for container access from actors

**Accessing Relationship Properties**:
SwiftData relationships must be unwrapped before accessing nested properties

```swift
// ❌ BROKEN - Trying to access properties on optional relationship
Text(coverage.product.name)  // Error: Value of optional type 'Product?' must be unwrapped

// ❌ BROKEN - Trying to pass array to Text() initializer
Text(participation.roleBadges)  // Error: Cannot convert '[String]' to 'String'

// ✅ WORKS - Unwrap relationship and access nested property
if let product = coverage.product {
    Text(product.name)
}

// ✅ WORKS - Join array elements into string
Text(participation.roleBadges.joined(separator: ", "))
```

**Why this happens**:
- SwiftData relationships use optional types (`Product?`, `SamContext?`)
- Arrays in models are `[String]`, not `String`
- Swift's type safety requires explicit unwrapping and conversion

**Common patterns**:
```swift
// Relationship with fallback
Text(coverage.product?.name ?? "Unknown Product")

// Nested relationship access
if let product = coverage.product {
    Text(product.name)
    if let context = product.context {
        Text(context.name)
    }
}

// Array display with conditional
if !participation.roleBadges.isEmpty {
    Text(participation.roleBadges.joined(separator: ", "))
}
```

---

### 6.5 Store Singleton Pattern

**Critical**: On macOS, per-instance authorization cache means a second store will see stale `.notDetermined` forever

```swift
// ✅ CORRECT - Use shared instances
await ContactsService.shared.fetchContact(...)
let store = PermissionsManager.shared.contactStore

// ❌ WRONG - Creates duplicate store
let store = CNContactStore()  // Will have stale auth state!
```

**Affected Classes**:
- ContactsService owns the CNContactStore
- PermissionsManager provides shared access for special cases
- Never create stores in views, coordinators, or utilities

---

### 6.6 SwiftUI Patterns

#### Preview Return Statements

When preview closures contain multiple statements before returning the view, Swift requires an explicit `return` keyword:

```swift
// ❌ BROKEN - Type '()' cannot conform to 'View'
#Preview("My View") {
    let container = SAMModelContainer.shared
    PeopleRepository.shared.configure(container: container)
    
    MyView()
        .modelContainer(container)
}

// ✅ WORKS - Explicit return statement
#Preview("My View") {
    let container = SAMModelContainer.shared
    PeopleRepository.shared.configure(container: container)
    
    return MyView()
        .modelContainer(container)
}
```

**Single-expression previews** don't need explicit return (implicit):

```swift
// ✅ WORKS - Single expression, implicit return
#Preview("Simple") {
    MyView()
}
```

**Why this happens**:
- Swift's closure return type inference requires single expression for implicit return
- Multiple statements (let bindings, setup code) make the return type ambiguous
- Adding `return` explicitly tells the compiler what the closure returns

---

#### ForEach with Non-Identifiable Collections

When iterating over collections that don't conform to `Identifiable`, use `Array.enumerated()` with offset as ID:

```swift
// ❌ BROKEN - Generic parameter 'C' could not be inferred
ForEach(contact.phoneNumbers, id: \.value) { phone in
    Text(phone.value)
}

// ❌ BROKEN - Cannot convert '[PhoneNumberDTO]' to 'Binding<C>'
ForEach(person.participations) { participation in
    Text(participation.role)
}

// ✅ WORKS - Use enumerated() with offset as ID
ForEach(Array(contact.phoneNumbers.enumerated()), id: \.offset) { index, phone in
    Text(phone.value)
}

// ✅ WORKS - Works for SwiftData relationships too
ForEach(Array(person.participations.enumerated()), id: \.offset) { index, participation in
    Text(participation.role)
}
```

**When to use this pattern**:
- DTOs with nested collections (`ContactDTO.phoneNumbers`, `ContactDTO.emailAddresses`)
- SwiftData relationships without stable IDs (`person.participations`, `person.coverages`)
- Arrays where elements might not be unique or don't conform to `Identifiable`

**How it works**:
- `enumerated()` creates tuples of `(offset: Int, element: T)`
- `offset` is guaranteed unique within the collection (0, 1, 2, ...)
- `Array()` wrapper ensures `RandomAccessCollection` conformance
- SwiftUI uses offset as the stable ID for each row

**Performance**:
- `enumerated()` is lazy (O(1) setup)
- `Array()` forces evaluation but acceptable for small collections (< 100 items)
- Offset comparison is O(1) (integer equality)

**Caution - Offset IDs are not stable across mutations**:

```swift
// ⚠️ CAUTION - Don't use offset IDs for editable lists
ForEach(Array(items.enumerated()), id: \.offset) { index, item in
    // If user deletes item at index 2, all items after shift indices
    // SwiftUI may not animate correctly or may show wrong data
}

// ✅ BETTER - Use stable ID for editable lists
extension PhoneNumberDTO: Identifiable {
    var id: String { value + label }  // Composite key
}

ForEach(contact.phoneNumbers) { phone in
    Text(phone.value)
}
```

**For read-only lists** (most common case in SAM): offset IDs are fine.

**For editable lists**: Implement proper `Identifiable` conformance with stable IDs.

**Affected Views**:
- PersonDetailView: Phone numbers, participations, coverages, insights
- Any view displaying DTO nested collections or SwiftData relationships

---

### 6.7 SwiftData Model Selection in Lists

**The Problem**: Using SwiftData models directly in `NavigationLink` selection bindings can cause SwiftUI to show incorrect detail views — all items may display the first item's details even though the list renders correctly.

**Why This Happens**:
- SwiftUI uses identity and equality checks to track selection
- SwiftData models are reference types with complex identity semantics
- After data updates, SwiftUI may fail to correctly match selected models
- Even with explicit `id: \.id` in `ForEach`, the selection binding itself can fail

**The Solution**: Use primitive ID types (UUID, String, etc.) for selection state, not the model itself.

```swift
// ❌ BROKEN - Model in selection binding
@State private var selectedPerson: SamPerson?

List(selection: $selectedPerson) {
    ForEach(people, id: \.id) { person in
        NavigationLink(value: person) {  // Passing model as value
            PersonRowView(person: person)
        }
    }
}

// Detail view
if let selected = selectedPerson {
    PersonDetailView(person: selected)  // May show wrong person!
}

// ✅ CORRECT - UUID in selection binding
@State private var selectedPersonID: UUID?

List(selection: $selectedPersonID) {
    ForEach(people, id: \.id) { person in
        NavigationLink(value: person.id) {  // Passing ID as value
            PersonRowView(person: person)
        }
    }
}

// Detail view - look up by ID
if let selectedID = selectedPersonID,
   let selected = people.first(where: { $0.id == selectedID }) {
    PersonDetailView(person: selected)  // Correct person every time
}
```

**When to Apply This Pattern**:
- Any `List` with `NavigationLink` and `selection` binding
- Any list displaying SwiftData models
- Both master-detail and navigation stack patterns

**Affected Views**:
- ✅ PeopleListView (fixed in Phase D)
- Any future list views with selectable SwiftData models

**Related Patterns**:
- Always use explicit `id: \.id` in `ForEach` with SwiftData models
- For non-selectable lists, passing models to views is fine
- For toolbar/menu actions, fetch fresh model by ID when needed

---

### 6.8 Coordinator Consistency

**The Pattern**: Coordinators handling similar operations (import, sync, etc.) should expose **identical API shapes** for consistency.

**Why This Matters**:
- Enables code reuse across Settings views
- Reduces copy-paste errors
- Improves maintainability
- Makes testing easier (shared test utilities)

**Example of Good Consistency**:

```swift
// ✅ GOOD - Both coordinators have same API
ContactsImportCoordinator.shared.importStatus  // returns ImportStatus enum
CalendarImportCoordinator.shared.importStatus  // returns ImportStatus enum

ContactsImportCoordinator.shared.lastImportedAt  // returns Date?
CalendarImportCoordinator.shared.lastImportedAt  // returns Date?

await ContactsImportCoordinator.shared.importNow()  // async func
await CalendarImportCoordinator.shared.importNow()  // async func
```

**Example of Bad Inconsistency** (current state, to be fixed):

```swift
// ❌ BAD - Inconsistent APIs
ContactsImportCoordinator.shared.isImporting      // returns Bool
CalendarImportCoordinator.shared.importStatus     // returns ImportStatus enum

ContactsImportCoordinator.shared.lastImportResult  // returns ImportResult?
CalendarImportCoordinator.shared.lastImportedAt    // returns Date?
```

**Current Status**:
- **CalendarImportCoordinator** follows the standard (Phase E)
- **ContactsImportCoordinator** uses older pattern (Phase C, predates standard)
- See §2.4 for standard coordinator API template
- Migration planned for Phase F or I

**When Building New Coordinators**:
1. Copy CalendarImportCoordinator as template
2. Use `ImportStatus` enum (not Bool for state)
3. Provide `lastImportedAt: Date?` (not custom result types)
4. Make `importNow()` async (wrap in Task at call site)
5. Use `@ObservationIgnored` for UserDefaults-backed settings

---

## 7. Testing Strategy

### Unit Testing Approach

Each layer tested independently:

```swift
import Testing

@Suite("ContactsService Tests")
struct ContactsServiceTests {
    
    @Test("Fetch contact returns DTO")
    func testFetchContact() async throws {
        let contact = await ContactsService.shared.fetchContact(
            identifier: "test-id",
            keys: .minimal
        )
        #expect(contact != nil)
    }
}

@Suite("PeopleRepository Tests")
struct PeopleRepositoryTests {
    
    @Test("Upsert creates new person")
    func testUpsert() throws {
        let repo = PeopleRepository()
        repo.configure(container: testContainer)
        
        let dto = ContactDTO(
            identifier: "123",
            givenName: "John",
            familyName: "Doe"
        )
        
        try repo.upsert(contact: dto)
        
        let people = try repo.fetchAll()
        #expect(people.count == 1)
        #expect(people.first?.displayNameCache == "John Doe")
    }
}
```

**Testing Guidelines**:
- Services: Test with real CNContactStore (requires authorization)
- Repositories: Use in-memory ModelContainer
- Coordinators: Mock services/repositories with protocols
- Views: Use SwiftUI preview data

---

## 8. Common Development Tasks

### Adding a New Feature

**Checklist**:
- [ ] Does it need external API access? → Add method to appropriate Service
- [ ] Does it need persistent storage? → Add method to appropriate Repository
- [ ] Does it need business logic? → Create/update Coordinator
- [ ] Does it need UI? → Create View that uses DTOs
- [ ] Is all data crossing actors `Sendable`?
- [ ] Are all CNContact/EKEvent accesses through Services?
- [ ] Can it be tested without launching the full app?

### Debugging Permission Issues

1. Check authorization status: `await contactsService.authorizationStatus()`
2. Verify using shared store: `ContactsService.shared` or `PermissionsManager.shared.contactStore`
3. Look for direct CNContactStore creation (search codebase for `CNContactStore()`)
4. Check if method checks auth before data access
5. Review PermissionsManager logs for auth changes

### Debugging Concurrency Issues

1. Check actor isolation: Services are `actor`, Repositories are `@MainActor`
2. Verify DTOs are `Sendable` (structs with Sendable members)
3. Look for `nonisolated(unsafe)` (should be rare/never)
4. Check for CNContact/EKEvent crossing boundaries (should never happen)
5. Enable Swift 6 complete concurrency checking: `-strict-concurrency=complete`

---

## 10. Key Files Reference

### Documentation

- **context.md** (this file): Current architecture, active phases, future roadmap
- **changelog.md**: Completed phases, architectural decisions, historical notes
- **agent.md**: Product philosophy and AI assistant guidelines

### Core Implementation Files

**Foundation**:
- `SAMApp.swift`: App entry point, coordinator kickoff
- `SAMModelContainer.swift`: SwiftData configuration
- `AppShellView.swift`: Navigation shell
- `SAMModels.swift`: All @Model definitions

**Services** (Actor-isolated, returns DTOs):
- `ContactsService.swift`: All CNContact operations
- `PermissionsManager.swift`: Authorization management

**Repositories** (@MainActor, SwiftData CRUD):
- `PeopleRepository.swift`: SamPerson operations
- `EvidenceRepository.swift`: SamEvidenceItem operations (partial)

**Coordinators** (@MainActor when needed):
- `ContactsImportCoordinator.swift`: Orchestrates contact import

**DTOs** (Sendable):
- `ContactDTO.swift`: CNContact wrapper with nested types

---

## 11. Success Metrics

**We know the rebuild succeeded when**:
- ✅ No direct CNContactStore/EKEventStore access outside Services/
- ✅ No `nonisolated(unsafe)` escape hatches
- ✅ All concurrency warnings resolved
- ✅ Each layer has < 10 files (cohesive responsibilities)
- 🎯 New features take < 1 hour to add (vs. full day of debugging)
- 🎯 Tests run in < 2 seconds (fast feedback loop)
- 🎯 Zero permission dialog surprises during normal operation

---

## 12. Development Environment

### Requirements

- macOS 14.0+
- Xcode 16.0+ (Swift 6)
- Access to Contacts and Calendar (for testing)

### Build Settings

- Swift Language Version: Swift 6
- Concurrency Checking: Complete (`-strict-concurrency=complete`)
- Minimum macOS Deployment: 14.0

### Test Data Setup

1. Create test Contacts group named "SAM"
2. Add 5-10 test contacts to group
3. Create test Calendar named "SAM"
4. Add upcoming test events
5. Grant permissions in Settings → Permissions

---

## 13. Support & Documentation

### Questions?

- Check **CLEAN_REBUILD_PLAN.md** for phase-by-phase guidance
- Review **PHASE_*_COMPLETE.md** for implementation details
- Read relevant Service/Repository file headers for API documentation

### Reporting Issues

When reporting bugs or architectural concerns:
1. Which layer is involved? (View/Coordinator/Service/Repository)
2. Which phase does it belong to?
3. Is it a concurrency issue, permission issue, or logic issue?
4. Include relevant logs (search for service/coordinator name in console)

---

## 14. Future Enhancements

**Post-Phase M** (after all core phases complete):

- **Advanced Search**: Full-text search across evidence, notes, and insights
- **Export/Import**: Backup and restore SAM data (SwiftData export)
- **Multi-language**: Localization support
- **Performance**: Optimize large dataset handling (10,000+ contacts)
- **Mail Integration**: Email thread observation and analysis
- **Zoom/Teams Integration**: Alternative to iMessage/FaceTime if APIs unavailable
- **Advanced Analytics**: Relationship health scoring, engagement metrics
- **Calendar Writing**: Create follow-up events from insights (requires calendar write permission)

