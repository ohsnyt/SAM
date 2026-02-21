:context.md
# SAM — Project Context
**Platform**: macOS  
**Language**: Swift 6  
**Architecture**: Clean layered architecture with strict separation of concerns  
**Framework**: SwiftUI + SwiftData  
**Last Updated**: February 20, 2026 (Phases A–L-2 complete)

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

**Current Status (February 12, 2026)**:
- ✅ **CalendarImportCoordinator** - Follows standard pattern (Phase E)
- ✅ **NoteAnalysisCoordinator** - Follows standard pattern (Phase H)
- ✅ **InsightGenerator** - Follows standard pattern with `GenerationStatus` (Phase I)
- ⚠️ **ContactsImportCoordinator** - Uses older pattern (Phase C, predates standard)
  - Uses `isImporting: Bool` instead of `importStatus: ImportStatus`
  - Uses `lastImportResult: ImportResult?` instead of `lastImportedAt: Date?`
  - **To be refactored** in Phase J for consistency

**Migration Note**: When refactoring ContactsImportCoordinator, add new properties alongside old ones temporarily, then migrate all call sites before removing deprecated properties.

---

## 3. Project Structure

```
SAM/SAM/
├── App/
│   ├── SAMApp.swift                    ✅ App entry point, lifecycle, permissions
│   └── SAMModelContainer.swift         ✅ SwiftData container (v6 schema)
│
├── Services/
│   ├── ContactsService.swift           ✅ Actor — CNContact operations
│   ├── CalendarService.swift           ✅ Actor — EKEvent operations
│   ├── NoteAnalysisService.swift       ✅ Actor — On-device LLM (Apple Foundation Models)
│   ├── MailService.swift               ✅ Actor — Mail.app AppleScript bridge
│   ├── EmailAnalysisService.swift     ✅ Actor — On-device email LLM analysis
│   ├── DictationService.swift         ✅ Actor — SFSpeechRecognizer on-device dictation
│   └── ENEXParserService.swift        ✅ Actor — Evernote ENEX XML parser
│
├── Coordinators/
│   ├── ContactsImportCoordinator.swift ✅ Orchestrates contact import
│   ├── CalendarImportCoordinator.swift ✅ Orchestrates calendar import
│   ├── NoteAnalysisCoordinator.swift   ✅ Save → analyze → store pipeline
│   ├── InsightGenerator.swift          ✅ Multi-source insight generation
│   ├── MailImportCoordinator.swift     ✅ Orchestrates email import (standard API pattern)
│   └── EvernoteImportCoordinator.swift ✅ ENEX file import (parse → preview → import)
│
├── Repositories/
│   ├── PeopleRepository.swift          ✅ CRUD for SamPerson
│   ├── EvidenceRepository.swift        ✅ CRUD for SamEvidenceItem
│   ├── ContextsRepository.swift        ✅ CRUD for SamContext
│   └── NotesRepository.swift           ✅ CRUD for SamNote + analysis storage
│
├── Models/
│   ├── SAMModels.swift                 ✅ Core @Model classes (SamPerson, SamContext, etc.)
│   ├── SAMModels-Notes.swift           ✅ SamNote (simplified L-2), SamAnalysisArtifact
│   ├── SAMModels-Supporting.swift      ✅ Value types, enums, chips
│   └── DTOs/
│       ├── ContactDTO.swift            ✅ Sendable CNContact wrapper
│       ├── EventDTO.swift              ✅ Sendable EKEvent wrapper
│       ├── EmailDTO.swift              ✅ Sendable IMAP message wrapper
│       ├── EmailAnalysisDTO.swift      ✅ Sendable email LLM analysis results
│       ├── NoteAnalysisDTO.swift       ✅ Sendable note LLM analysis results
│       ├── EvernoteNoteDTO.swift       ✅ Sendable ENEX parsed note
│       └── OnboardingView.swift        ✅ First-run permission onboarding
│
├── Views/
│   ├── AppShellView.swift              ✅ Three-column navigation shell
│   ├── People/
│   │   ├── PeopleListView.swift        ✅ People list with search & import
│   │   └── PersonDetailView.swift      ✅ Full contact detail + notes/evidence
│   ├── Inbox/
│   │   ├── InboxListView.swift         ✅ Evidence triage list
│   │   └── InboxDetailView.swift       ✅ Evidence detail + triage actions
│   ├── Contexts/
│   │   ├── ContextListView.swift       ✅ Context list with filter/search
│   │   └── ContextDetailView.swift     ✅ Context detail + participant mgmt
│   ├── Awareness/
│   │   └── AwarenessView.swift         ✅ Insights dashboard with filtering
│   ├── Notes/
│   │   ├── NoteEditorView.swift        ✅ Edit-only note editor (Phase L-2)
│   │   ├── InlineNoteCaptureView.swift ✅ Inline note capture with dictation (Phase L-2)
│   │   ├── NotesJournalView.swift      ✅ Scrollable inline journal with in-place editing
│   │   └── NoteActionItemsView.swift   ✅ Review extracted action items
│   ├── Shared/
│   │   ├── NotInContactsCapsule.swift  ✅ Reusable "Not in Contacts" badge + add-to-contacts action
│   │   └── RoleBadgeStyle.swift        ✅ Shared role→color/icon mapping + RoleBadgeIconView (compact list icon with popover tooltip)
│   ├── Settings/
│   │   ├── SettingsView.swift          ✅ Tabbed: Permissions, Contacts, Calendar, Mail, Intelligence, Evernote, General
│   │   ├── MailSettingsView.swift      ✅ Mail.app accounts, Me-contact email filter toggles
│   │   └── EvernoteImportSettingsView.swift ✅ ENEX file picker, preview, import
│   └── ContactValidationDebugView.swift  🔧 Debug utility
│
├── Utilities/
│   ├── DevLogStore.swift               ✅ Actor-isolated dev logging
│   ├── MailFilterRule.swift            ✅ Email recipient filtering rules
│   └── ContactsTestView.swift          🔧 Debug utility
│
└── 1_Documentation/
    ├── context.md                      This file
    ├── changelog.md                    Completed work history
    └── agent.md                        Product philosophy & UX principles
```

**Legend**:
- ✅ Complete and following clean architecture
- 🔧 Debug/development utility
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
    var roleBadges: [String]            // Predefined: Client, Applicant, Lead, Vendor, Agent, External Agent (+ custom)
    var consentAlertsCount: Int
    var reviewAlertsCount: Int
    
    // Relationships (SAM-owned)
    var participations: [ContextParticipation]
    var coverages: [Coverage]
    var insights: [SamInsight]
    var notes: [SamNote]                // User-created notes (Phase H)
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
    var sourceRawValue: String          // EvidenceSource enum (.calendar, .mail, .contacts, .note, .manual)
    var sourceUID: String?              // EKEvent.eventIdentifier, CNContact.identifier, etc.
    var snippet: String?                // Brief content preview
    var observedAt: Date
    var triageStateRawValue: String     // EvidenceTriageState enum (.needsReview, .done)
    var linkedPeople: [SamPerson]
    var linkedContexts: [SamContext]
    var participantHints: [ParticipantHint]  // Calendar attendee info for matching
    var signals: [EvidenceSignal]       // Deterministic signals extracted from evidence
}
```

**SamNote**: User-created notes with on-device LLM analysis (Phase H)
```swift
@Model
final class SamNote {
    var content: String                 // Raw note text (user-entered)
    var summary: String?                // LLM-generated summary
    var createdAt: Date
    var updatedAt: Date
    var isAnalyzed: Bool                // Whether LLM analysis has run
    var analysisVersion: Int            // Bump to trigger re-analysis
    var linkedPeople: [SamPerson]       // Many-to-many (queried, not inverse)
    var linkedContexts: [SamContext]
    var linkedEvidence: [SamEvidenceItem]
    var extractedMentions: [ExtractedPersonMention]  // LLM-extracted people
    var extractedActionItems: [NoteActionItem]       // LLM-extracted actions
    var extractedTopics: [String]       // LLM-extracted topics
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

**UndoEntry**: Universal undo system (Phase N)
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
- ✅ **Phase D**: People UI (PeopleListView, PersonDetailView)
- ✅ **Phase E**: Calendar & Evidence (CalendarService, EventDTO, CalendarImportCoordinator, EvidenceRepository)
- ✅ **Phase F**: Inbox UI (InboxListView, InboxDetailView, evidence triage)
- ✅ **Phase G**: Contexts (ContextsRepository, ContextListView, ContextDetailView)
- ✅ **Phase H**: Notes & Note Intelligence (NotesRepository, NoteAnalysisService, NoteEditorView, on-device LLM)
- ✅ **Phase I**: Insights & Awareness (InsightGenerator, AwarenessView, multi-source generation)
- ✅ **Phase J (Part 1)**: Email Integration scaffolding (DTOs, repositories, coordinator, settings view)
- ✅ **Phase J (Part 2)**: Mail.app AppleScript integration (replaced IMAP stubs with working NSAppleScript bridge)
- ✅ **Phase J (Part 3a)**: "Me" contact identification + email integration UX tweaks
- ✅ **Phase J (Part 3b — Marketing Detection)**: Mailing list / marketing sender auto-detection + triage UI split (Feb 17, 2026)
- ✅ **Phase J (Part 3c)**: Hardening — participant matching fix + insight persistence to SwiftData (Feb 20, 2026)
- ✅ **Phase K**: Meeting Prep & Follow-Up (briefings, follow-up coach, relationship health) (Feb 20, 2026)
- ✅ **Phase L**: Notes Pro — timestamped entries, dictation, Evernote ENEX import (Feb 20, 2026)
- ✅ **Phase L-2**: Notes Redesign — simplified model, inline capture, AI polish, auto-linking, relationship summaries (Feb 20, 2026)

**Known Bugs**: (none currently tracked)

**Next Up**:
- ⬜ **Phase M**: iMessage Evidence
- ⬜ **Phase N**: Universal Undo System
- ⬜ **Phase O**: Time Tracking

---

### ✅ Phase J: Email Integration & Polish (COMPLETE — Feb 20, 2026)

Mail.app AppleScript bridge, on-device LLM email analysis, known-sender filtering, unknown sender triage, marketing detection, "Me" contact identification, participant matching fix, insight persistence to SwiftData. See `changelog.md` for full implementation details.

**Open polish items** (non-blocking):
- ⬜ "Add to Context" from PersonDetailView — wire up context selection sheet
- ⬜ Remove debug utilities from production — ContactsTestView, ContactValidationDebugView

---

### ✅ Phase K: Meeting Prep & Follow-Up (COMPLETE — Feb 20, 2026)

MeetingPrepCoordinator generates 48h-lookahead briefings and follow-up prompts. RelationshipHealthView shows interaction frequency and trend. Sections embedded in AwarenessView and PersonDetailView. See `changelog.md` for full implementation details.

---

### ✅ Phase L: Notes Pro (COMPLETE — Feb 20, 2026)

NoteEntry value type + entry stream UI, DictationService (SFSpeechRecognizer), ENEXParserService + EvernoteImportCoordinator, EvernoteImportSettingsView. SamNote model upgraded with entries array + sourceImportUID. Schema bumped to SAM_v7. See `changelog.md` for full details.

---

### ✅ Phase L-2: Notes Redesign (COMPLETE — Feb 20, 2026)

Simplified note model (removed NoteEntry, one note = one text block + sourceType). Inline note capture (InlineNoteCaptureView) replaces sheet-based editor for new notes. NoteEditorView simplified to edit-only. AI dictation polish (polishDictation). Smart auto-linking to recent calendar events (findRecentMeeting). AI relationship summary on PersonDetailView (overview, key themes, next steps). Schema bumped to SAM_v8.

**Post-release fixes (Feb 20):** Dictation fixed (missing audio-input entitlement, microphone permission flow, silence auto-stop, text accumulation across recognizer resets). NotesJournalView replaces tap-to-edit sheet with scrollable inline journal. NotInContactsCapsule shared view replaces static badges in PeopleListView and InboxDetailView. Stale contactIdentifier detection during sync. SAM-created contacts auto-added to SAM group. Role badge system: predefined roles (Client, Applicant, Lead, Vendor, Agent, External Agent), color-coded compact icons in People list (RoleBadgeStyle/RoleBadgeIconView), editable capsules in PersonDetailView, notification-based list refresh. Me contact: distinct "Me" label in People list, non-editable badge in detail view, hidden from event/email participant displays.

---

### ⬜ Phase M: iMessage Evidence (NOT STARTED)

**Goal**: Observe iMessage interactions as evidence for relationship awareness

**Tasks**:
- ⬜ Research macOS iMessage database access (~/Library/Messages/chat.db)
- ⬜ Create iMessageService.swift (actor, reads SQLite database)
  - Returns MessageDTO (Sendable wrapper with metadata only)
  - Checks Full Disk Access authorization
- ⬜ Create iMessageImportCoordinator.swift
  - Fetches message metadata (sender, timestamp, conversation)
  - Creates Evidence items linked to SamPerson by phone/email
  - Privacy-first: store metadata + analysis, not raw message content
- ⬜ Add iMessage evidence to Inbox
  - Evidence source type: `.iMessage`
  - Display conversation metadata, not full content

**Architecture Notes**:
- No public API for iMessage; requires reading SQLite database directly
- Requires Full Disk Access entitlement
- Privacy-first: store metadata + AI summary, never raw message bodies
- Link to SamPerson via phone number or email address matching

**Expected Outcome**: iMessage interaction history appears as Evidence, feeds relationship health metrics

---

### ⬜ Phase N: Universal Undo System (NOT STARTED)

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

**Expected Outcome**: User can undo any destructive action within 30 days

**Architecture Notes**:
- Undo != NSUndoManager (incompatible with SwiftData)
- Store snapshots as JSON (Codable)
- Repository pattern: all mutations go through repositories, so easy to intercept

---

### ⬜ Phase O: Time Tracking (NOT STARTED)

**Goal**: Allow user to document time spent on activities

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
- **NoteAnalysisCoordinator** follows the standard (Phase H)
- **InsightGenerator** follows the standard with `GenerationStatus` (Phase I)
- **ContactsImportCoordinator** uses older pattern (Phase C, predates standard)
- See §2.4 for standard coordinator API template
- Migration planned for Phase J

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
- `SAMApp.swift`: App entry point, lifecycle, permission checks, repository configuration
- `SAMModelContainer.swift`: SwiftData container (v8 schema — Phase L-2 simplified notes)
- `AppShellView.swift`: Three-column navigation shell (sidebar → list → detail)

**Models** (SwiftData @Model):
- `SAMModels.swift`: Core models — SamPerson, SamContext, SamEvidenceItem, SamInsight, ContextParticipation, etc.
- `SAMModels-Notes.swift`: SamNote, SamAnalysisArtifact
- `SAMModels-Supporting.swift`: Value types — ParticipantHint, EvidenceSignal, ExtractedPersonMention, NoteActionItem, enums

**Services** (Actor-isolated, returns DTOs):
- `ContactsService.swift`: All CNContact operations
- `CalendarService.swift`: All EKEvent operations
- `NoteAnalysisService.swift`: On-device LLM analysis via Apple Foundation Models

**Repositories** (@MainActor, SwiftData CRUD):
- `PeopleRepository.swift`: SamPerson operations (upsert, bulk, email cache)
- `EvidenceRepository.swift`: SamEvidenceItem operations (bulk upsert, email resolution, pruning)
- `ContextsRepository.swift`: SamContext operations (participant management)
- `NotesRepository.swift`: SamNote operations (analysis storage, action items)

**Coordinators** (@MainActor, orchestration):
- `ContactsImportCoordinator.swift`: Contact import with debouncing/throttling
- `CalendarImportCoordinator.swift`: Calendar import (standard API pattern)
- `NoteAnalysisCoordinator.swift`: Save → analyze → store pipeline
- `InsightGenerator.swift`: Multi-source insight generation (notes, relationships, calendar)

**DTOs** (Sendable):
- `ContactDTO.swift`: CNContact wrapper with nested types (PhoneNumberDTO, etc.)
- `EventDTO.swift`: EKEvent wrapper with AttendeeDTO
- `NoteAnalysisDTO.swift`: LLM analysis results (PersonMentionDTO, ActionItemDTO)

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

**Post-Phase O** (after all core phases complete):

- **Advanced Search**: Full-text search across evidence, notes, mail summaries,Plea and insights
- **Export/Import**: Backup and restore SAM data (SwiftData export)
- **Multi-language**: Localization support
- **Performance**: Optimize large dataset handling (10,000+ contacts)
- **Mail Integration**: Email thread observation and analysis
- **Zoom/Teams Integration**: Alternative to iMessage/FaceTime if APIs unavailable
- **Advanced Analytics**: Relationship health scoring, engagement metrics
- **Calendar Writing**: Create follow-up events from insights (requires calendar write permission)
- **Contact Editing**: Limited contact field editing from SAM (sync back to Contacts)
- **Custom Activity Types**: User-defined time tracking categories
- **Undo Compression**: Archive old undo entries to reduce storage

**Long-term**:
- **iOS Companion**: Read-only iOS app (separate architecture, phase TBD)
- **Team Collaboration**: Shared contexts and evidence (multi-user support)
- **API Integration**: Connect to financial planning software (CRM sync)
- **Advanced AI**: Custom LLM fine-tuning for financial advisor insights
- **Relationship Graph**: Visual network of people, contexts, and connections

---

**Document Version**: 5.0 (Phases A–L complete)
**Previous Versions**: See `changelog.md` for version history
**Last Major Update**: February 20, 2026 — Role badges, Me contact visibility, Notes Redesign
**Clean Rebuild Started**: February 9, 2026

