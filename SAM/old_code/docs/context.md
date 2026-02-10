
THIS IS THE ANCHOR-FREE VERSION (for verification)

# SAM – Project Context

_Last updated: 2026-02-08 (Phase 1: UX Improvements - Note Indicator, Badges, Me Card)_

See also: Changelog and Consolidated Engineering History (refer to repository files).

---

## 1) Purpose & Principles

- Native macOS SwiftUI application for independent financial strategists. Observes interactions (Calendar, Contacts, Notes), creates Evidence, and generates AI-backed Insights for relationship management.
- AI assists but never acts autonomously. User reviews and approves everything.
- Design values: Clarity, Responsiveness, Familiarity, Trust. Prefer standard macOS patterns.
- **New:** One-click suggestion workflow - AI detects life events and suggests comprehensive actions (add family members, update notes, send congratulations).

---

## 2) System Architecture (At-a-Glance)

- **Navigation:** NavigationSplitView with sidebar (Awareness, People, Contexts, Inbox). Sidebar selection via @AppStorage.
- **Data Models (@Model):** SamEvidenceItem, SamPerson, SamContext, SamInsight, SamNote, SamAnalysisArtifact, Product.
- **Identity Layer:** Apple Contacts is the system of record for identity data (names, family, contact info). SamPerson stores only `contactIdentifier` + cached display fields.
- **Repositories/Coordinators:** EvidenceRepository, PeopleRepository, CalendarImportCoordinator, ContactsImportCoordinator, ContactSyncService.
- **Singletons:** EvidenceRepository.shared, PeopleRepository.shared, CalendarImportCoordinator.eventStore, ContactsImportCoordinator.contactStore, ContactSyncService.shared (non-@MainActor, read methods thread-safe), SAMModelContainer.shared (nonisolated), PermissionsManager.shared.
- **Views (primary):** InboxListView/InboxDetailView/AwarenessHost, PeopleListView/PersonDetailHost, ContextListView/ContextDetailRouter.
- **Concurrency:** Swift 6 async/await; SAMModelContainer.shared and newContext() are nonisolated for background usage. ContactSyncService read methods are thread-safe; write methods are @MainActor.

### Architecture (Details)

- **Navigation:** NavigationSplitView with sidebar (Awareness, People, Contexts, Inbox). Sidebar selection via @AppStorage.
- **Identity Strategy (Contacts-First):**
  - Apple Contacts = System of record for identity (names, family relationships, contact info, dates)
  - SAM stores only `CNContact.identifier` as anchor + cached display fields (name, email, photo)
  - Family relationships read from `CNContact.contactRelations` (not duplicated in SAM)
  - Contact info (phone, email, address) read from CNContact on-demand (lazy loaded in detail view)
  - **Contact Notes:** Read/write access pending Apple entitlement approval (currently logs instead of writing)
  - SAM owns: Evidence, Insights, Contexts, Coverage, Consent tracking, cross-person links, Products
- **Data layer:**
  - @Model classes: SamEvidenceItem (Evidence), SamPerson (Identity Anchor), SamContext (Contexts), SamNote (User Notes), SamAnalysisArtifact (LLM Analysis), Product (Financial Products)
  - Repositories: EvidenceRepository (Evidence), PeopleRepository (People), ContactSyncService (Contacts sync with write operations)
  - Views: InboxListView, InboxDetailView, AwarenessHost (Evidence); PeopleListView, PersonDetailHost (People); ContextListView, ContextDetailRouter (Contexts)
  - **Smart Suggestions:** NoteEvidenceFactory generates ProposedLinks for detected family members; InboxDetailSections provides SuggestionActions for one-click application
- **Key singletons:** EvidenceRepository.shared / PeopleRepository.shared / ContactSyncService.shared (non-@MainActor); CalendarImportCoordinator.eventStore / ContactsImportCoordinator.contactStore; SAMModelContainer.shared (nonisolated); PermissionsManager.shared

---

## 3) Critical Gotchas (Must Follow)

### 3.1 Permissions (CNContactStore / EKEventStore)

- Any data access on CNContactStore/EKEventStore triggers a system dialog if not authorized.
- **Safe (no dialog):**
  ```swift
  CNContactStore.authorizationStatus(for: .contacts)
  EKEventStore.authorizationStatus(for: .event)
  ```
- **Unsafe calls (trigger permission dialog if not authorized):**
  ```swift
  store.unifiedContact(withIdentifier:keysToFetch:)
  store.unifiedContacts(matching:keysToFetch:)
  store.enumerateContacts(with:)
  store.groups(matching:)
  store.execute(saveRequest)
  eventStore.calendars(for:)
  eventStore.events(matching:)
  ```
- **The Rule:**
  ```swift
  // Always check authorization BEFORE any data access
  guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
      return nil  // or return false, or return []
  }
  // Now safe to access data
  let contact = try store.unifiedContact(...)
  ```
- **Best Practices:**
  1. Use a single shared store instance (singleton pattern) throughout the app
  2. Check authorization status before every data access operation
  3. Keep all permission requests in Settings → Permissions tab for user context
  4. Never create new CNContactStore() or EKEventStore() instances in views or helpers
  5. Pass the shared store as a parameter to utility functions
- **Affected Files:**
  - ContactValidator.swift - Must guard all validation methods
  - PersonDetailView.swift - Must use shared store for photo fetching
  - ContactsImportCoordinator.swift - Owns the shared CNContactStore
  - PermissionsManager.swift - Owns the authorization flow

### Store & Singleton Management
- EKEventStore, CNContactStore, EvidenceRepository, PeopleRepository are singletons. On macOS, per-instance auth cache means a second EKEventStore will see stale .notDetermined forever. Never create duplicates.
- Repositories fallback to full schema (SAMSchema.allModels with "SAM_v2" config) if not configured. This prevents schema-mismatch crashes during early initialization.

### SwiftData Enum Storage
Never store enums directly in @Model classes. SwiftData schema validation fails with "rawValue is not a member" errors. Pattern: Store raw value + @Transient computed property:
```swift
var stateRawValue: String
@Transient var state: EvidenceTriageState {
  get { EvidenceTriageState(rawValue: stateRawValue) ?? .needsReview }
  set { stateRawValue = newValue.rawValue }
}
```
Predicates:
```swift
#Predicate { $0.stateRawValue == "needsReview" }
let target = "needsReview"; #Predicate { $0.stateRawValue == target }
```

### SwiftData Relationships
- Inverse relationships cannot be optional: `var supportingInsights: [SamInsight] = []` (not `[SamInsight]?`)
- Delete order: Evidence → Contexts → People (reverse of insert to avoid cascade issues)

### SwiftUI & Predicates
- InboxDetailLoader uses unfiltered @Query + `.first { $0.id == id }`. Dynamic #Predicate in custom init crashes Swift 6.2 compiler.
- `.searchable` on HSplitView/NavigationStack, not on List (causes phantom padding flicker on macOS)

### Throttling & Timing
- Periodic triggers (app launch/activate) = 5min interval
- Event-driven triggers (calendar/contacts changed, permission granted) = 10sec interval
- PopoverAnchorView sets binding in updateNSView (not makeNSView) to avoid layout recursion

### Permissions & Auth
- All permission prompts originate from Settings only
- ContactValidator must not check authorizationStatus before operations—attempt directly and catch errors

### Backup & Crypto
- kCCPRFHmacAlgoSHA256 not bridged on macOS; named constant + precondition guards value changes
- Restore deletes in reverse-dependency order
- bulkUpsertFromContacts is best-effort (logs per-item errors but commits successes)

### Contacts-as-Identity Architecture
**Philosophy:** Apple Contacts is the system of record for identity. SAM is the system of record for relationship intelligence.

**What Lives in Contacts (Apple owns):**
- Names (given, family, middle, nickname, prefix, suffix, phonetic)
- Family relationships (`CNContact.contactRelations`: spouse, children, parents, siblings)
- Contact methods (phone, email, postal address, social profiles, IM handles)
- Dates (birthday, anniversary, custom dates)
- Professional info (company, job title, department)
- User-edited summary note (AI-suggested, user-approved, stored in `CNContact.note`)

**What Lives in SAM (We own):**
- Evidence (meetings, emails, notes, interactions)
- Insights (opportunities, risks, follow-ups, nudges)
- Contexts (households, businesses, teams — cross-person groupings)
- Coverage/Products (policies, accounts, assets)
- Consent requirements (compliance tracking)
- Tasks/Follow-ups (action items)
- Cross-person links (spouse ↔ spouse, parent ↔ child via `contactIdentifier`)
- Role badges ("Client", "Lead", "Referral Partner")
- Relationship health scores

**SamPerson Data Model (Minimal Anchor):**
```swift
@Model
public final class SamPerson {
    @Attribute(.unique) public var id: UUID
    public var contactIdentifier: String  // CNContact.identifier (required)
    
    // Cached for performance (refreshed on sync)
    public var displayNameCache: String?
    public var emailCache: String?
    public var photoThumbnailCache: Data?
    public var lastSyncedAt: Date?
    
    // SAM-specific metadata
    public var roleBadges: [String] = []
    public var relationshipHealthScore: Double?
    public var isArchived: Bool = false  // For soft-delete when contact removed
    
    // Relationships (SAM-owned)
    @Relationship public var contexts: [ContextParticipation]
    @Relationship public var insights: [SamInsight]
    @Relationship public var evidence: [SamEvidenceItem]
    @Relationship public var coverages: [Coverage]
    @Relationship public var consentRequirements: [ConsentRequirement]
}
```

**Contact Record Creation Rules:**
1. Create CNContact only when we contact or are contacted by someone
2. Create CNContact when contact information is provided (email, phone)
3. For extracted dependents (children): Add to parent's `CNContact.contactRelations` (no separate contact unless contact info exists)

**Contact Deletion Handling:**
- When CNContact deleted externally: Mark `SamPerson.isArchived = true`
- "Unlinked" badge appears in UI with options:
  - Archive (remove from active views)
  - Resync (attempt to find contact again)
  - Cancel (keep in limbo state)

**Contacts Sync Settings (User-Controlled):**
- Default: User approval required for all Contact writes
- Optional automatic modes (separate toggles):
  - Auto-add new family members to CNContact
  - Auto-update CNContact summary notes
  - Auto-archive SAM people when CNContact deleted
- Settings location: Settings → Contacts tab

**Performance Strategy:**
- Cache display fields (name, email, photo) in SamPerson for list performance
- Lazy-load full CNContact only in detail view
- Bulk cache refresh on app launch and Contacts change notifications
- Use CNContactStore change history API to detect external edits

---

## 4) Current Capabilities (High Signal)

### Calendar & Contacts Integration
- User selects/creates a "SAM" calendar; imports events with throttled updates
- Contacts group-based import via PeopleRepository
- Single shared EKEventStore and CNContactStore (per-instance auth cache on macOS)
- Pruning: removes Evidence when events deleted or moved out of SAM calendar
- Contact validation & sync with auto-clear of stale contactIdentifier values

### Evidence, Signals & Insights
- Calendar events → Evidence with deterministic signals
- InsightGenerator creates persisted SamInsight from signals
- Evidence relationships: SamInsight.basedOnEvidence ↔ SamEvidenceItem.supportingInsights
- Automatic generation after imports (debounced)

### Inbox
- Shows Evidence needing review; link to People/Contexts; accept/decline proposed links
- Fully migrated to SwiftData (@Query on SamEvidenceItem)
- Participant resolution via background CNContactStore lookup

### People & Contexts
- Create/manage People and Contexts (Household, Business, Recruiting)
- Duplicate detection; person merge via LinkContactSheet
- Fully migrated to SwiftData (@Query on SamPerson and SamContext)
- Contact linking with photo fetch; unlinked badge flow

### Awareness
- Groups signals into categories: Needs Attention, Follow-Ups, Opportunities

### Backup & Restore
- AES-256-GCM + PBKDF2 encrypted backups with versioned DTOs
- Restore re-links relationships by UUID

### Settings
- Calendar/Contacts permissions and configuration
- All system permission prompts originate from Settings only

### Developer Tools
- DEBUG-only fixture seeding (FixtureSeeder)
  - Imports contacts from SAM group only (respects architectural boundary)
  - Requires "SAM" group in Contacts.app with test contacts
  - Clears all data, imports contacts/calendar, creates test product and note
  - Triggers full LLM analysis pipeline automatically
- Development tab in Settings:
  - Export developer logs as text file
  - Clear logs button
  - Restore developer fixture (DEBUG-only, properly async/await compliant)
  - Deduplicate insights utility

### UX Enhancements (Phase 1 - Feb 8, 2026)
- **Note Processing Indicator** - Prominent orange card replaces subtle gray bar
  - Attention-grabbing color and animation
  - Clear messaging about AI analysis in progress
  - Component: `NoteProcessingIndicator.swift`
- **Badge System** - Action item counts on sidebar tabs
  - Awareness: Shows people/contexts needing attention (orange badge)
  - Inbox: Shows evidence needing review (blue badge)
  - People: Shows unlinked contacts (yellow badge)
  - Real-time updates on data changes
- **Me Card Badge** - Identifies user's own contact
  - Blue "Me" badge on user's contact in people list
  - Persisted in UserDefaults
  - Manager: `MeCardManager.swift`
  - Extension: `SamPerson.isMeCard` computed property

---

## 5) Recent Fixes (Why They Matter)

### FixtureSeeder Async/Concurrency Fixes — COMPLETE (Feb 8, 2026)
**Problem:**
- Multiple Swift 6 strict concurrency errors blocking builds
- `FixtureSeeder.seedIfNeeded()` (async) called without `await` in two locations
- `ContactsImporter.importAllContacts()` (async) called within synchronous `MainActor.run` block
- `ModelContext.reset()` called but this method doesn't exist in SwiftData
- FixtureSeeder importing ALL contacts from Contacts.app instead of just SAM group

**Root Causes:**
1. SAM_crmApp.swift: `performDestructiveReset()` was synchronous but called async fixture seeder
2. DevelopmentTab.swift: `wipeAndReseed()` wrapped async import in synchronous `MainActor.run`
3. DevelopmentTab.swift: Attempted to call non-existent `modelContext.reset()` API
4. FixtureSeeder.swift: Called `importAllContacts()` instead of `importFromSAMGroup()`

**Solutions Applied:**
1. **SAM_crmApp.swift** - Wrapped async call in `Task {}`:
   ```swift
   Task {
       await FixtureSeeder.seedIfNeeded(using: fresh)
   }
   ```
2. **DevelopmentTab.swift (line 213)** - Added `await` to async function:
   ```swift
   await FixtureSeeder.seedIfNeeded(using: container)
   ```
3. **FixtureSeeder.swift (line 106)** - Restructured to call async outside `MainActor.run`:
   ```swift
   let importer = await MainActor.run { ContactsImporter(modelContext: context) }
   let (imported, updated) = try await importer.importFromSAMGroup()
   ```
4. **DevelopmentTab.swift (line 215)** - Removed invalid `modelContext.reset()` call:
   - SwiftData doesn't have a reset() method
   - Deleted objects automatically trigger @Query refresh after save
   - Simplified to use main context directly instead of background context
5. **FixtureSeeder.swift** - Changed to respect SAM group boundary:
   - Now calls `importFromSAMGroup()` instead of `importAllContacts()`
   - Added specific error handling for missing SAM group
   - Updated all documentation and print statements

**Files Changed:**
- SAM_crmApp.swift - Added Task wrapper for async fixture seed
- DevelopmentTab.swift - Added await, removed invalid reset() call, simplified context usage
- FixtureSeeder.swift - Fixed async/await structure, changed to SAM group import only

**Result:** 
- All build errors resolved
- Full Swift 6 strict concurrency compliance maintained
- Fixture now respects architectural boundary (SAM group only)
- Proper async/await patterns throughout

**Setup Instructions:**
1. Create a "SAM" group in Contacts.app
2. Add test contacts (e.g., Harvey Snodgrass) to the SAM group
3. Run fixture - only SAM group contacts will be imported

---

### Contacts-as-Identity Architecture — IN PROGRESS (Feb 7, 2026)
**Problem:**
- SAM stored duplicate identity data (names, emails, family relationships)
- Extracted dependents (e.g., "William (son)") created as standalone people with no last name
- Users had to manually manage family data in two places (SAM and Contacts)
- Insights buried in UI, not actionable at point of extraction

**Architecture Decision:**
- Apple Contacts = System of record for identity (names, family, contact info, dates)
- SAM = System of record for relationship intelligence (evidence, insights, contexts, coverage)
- SamPerson stores only `CNContact.identifier` + cached display fields for performance

**Implementation Progress (Week 1, Day 1):**
- ✅ Created `ContactSyncService` (singleton) for fetch/write/cache operations
- ✅ Updated `SamPerson` model with cache fields (migration: SAM_v5 → SAM_v6)
- ✅ Created UI sections: FamilySection, ContactInfoSection, ProfessionalSection, SummaryNoteSection
- ✅ Created `AddRelationshipSheet` with editable name and relationship label fields
- ✅ Updated `NoteArtifactDisplay` to use editable sheet for adding family members
- ✅ Documented contact creation rules, deletion handling, sync settings, performance strategy
- 🚧 Next: Integrate sections into PersonDetailView, configure service in app init

**Key Rules:**
1. Create CNContact only when we contact/are contacted or when contact info provided
2. Dependents (children): Add to parent's `CNContact.contactRelations` (no separate contact unless contact info exists)
3. Orphaned contacts: Show "Unlinked" badge with Archive/Resync/Cancel options
4. Sync settings: User approval required by default; optional auto-modes in Settings

**User Experience Improvement:**
```
Before (6 steps):
1. Create note about William
2. View in Inbox
3. Expand "People" section
4. Click "Add Contact"
5. Contacts.app opens (empty)
6. Manually type everything

After (1 step):
1. Click "Add to Harvey's Family" → Done
   - William added to Harvey's CNContact.contactRelations
   - Visible in Contacts.app and SAM
   - Family data synchronized automatically
```

**Files Created/Modified:**
- Created: `ContactSyncService.swift`, `PersonDetailSections.swift`, implementation docs
- Modified: `SAMModels.swift` (cache fields), `context.md` (architecture docs)

---

### Permission Dialog UX Fix — COMPLETE (Feb 7, 2026)
**Problem:**
- Contacts permission dialog appeared unexpectedly at app startup
- Users saw permission requests without context before reaching Settings
- Intermediate confirmation dialogs created unnecessary friction

**Root Causes:**
- ContactValidator.isValid() called store.unifiedContact() without checking authorization first
- PersonDetailView created new CNContactStore() instances instead of using shared singleton
- Permission request flow had redundant confirmation alert before system dialog

**Solutions Applied:**
- Added authorization guards to ContactValidator.isValid() and isInSAMGroup()
- Changed to shared store - ContactPhotoFetcher now uses ContactsImportCoordinator.contactStore
- Removed intermediate alerts - Buttons now go directly to system permission dialogs
- Centralized permission flow - All requests route through Settings → Permissions tab

**Files Changed:**
- ContactValidator.swift - Added CNContactStore.authorizationStatus guards before all data access
- PersonDetailView.swift - Switched to shared store singleton
- SamSettingsView.swift - Removed redundant confirmation alerts, streamlined button flow

**Result:** Clean permission flow with no surprise dialogs. Users only see permission requests when they explicitly click buttons in Settings.

---

### Freeform Notes as Evidence — Notes-first COMPLETE (Feb 7, 2026)
**Fully Working Features:**
- Note Creation: "Add Note" button in Inbox toolbar and Person detail page
  - Sheet UI with person selection (pre-selects context person automatically)
  - Note saves with linked people relationships
- Entity Extraction (Heuristic): NoteLLMAnalyzer extracts from note text:
  - People: Detects names with relationships (e.g., "William (child)" from "I just had a son. His name is William")
  - Financial Topics: Detects life insurance, retirement, annuities, 401k/IRA mentions with amounts
  - Facts: Follow-up requests, action items
  - Implications: Opportunities, risks, concerns
  - Affect: Positive/neutral/negative sentiment
- Evidence Pipeline: Complete flow working:
  - SamNote (SwiftData) → SamAnalysisArtifact → SamEvidenceItem → signals → SamInsight
  - Notes appear in Inbox with state=needsReview
  - Evidence items linked to selected people via bidirectional @Relationship
- Insight Generation:
  - Signals generated from extracted facts/implications
  - Insights created with detailed messages including topics (e.g., "Possible opportunity regarding life insurance, retirement (Harvey Snodgrass)")
  - Insights properly linked to people and appear on their detail pages
- Schema & Relationships:
  - Added SamNote and SamAnalysisArtifact to schema (SAM_v5 database)
  - Fixed bidirectional inverse relationships: SamPerson.insights ↔ SamInsight.samPerson
  - Made 20+ models/enums public for factory pattern access control
- Developer Tools:
  - "Restore developer fixture" button now properly deletes all data in dependency order
  - Comprehensive debug logging throughout entire pipeline

**Recent Improvements (Feb 7, 2026):**
- ✅ Signal generation now uses structured LLM data (people, topics with sentiment) instead of just keyword matching
- ✅ SamAnalysisArtifact stores structured entities (peopleJSON, topicsJSON) with computed properties for access
- ✅ Two-tier signal mapper: Priority 1 = structured data (high confidence), Priority 2 = heuristic fallback
- ✅ AnalysisArtifactCard UI component created and integrated into InboxDetailView
- ✅ Insights properly generated from note opportunities (topics with "wants"/"interest"/"increase" sentiment)
- ✅ **Artifact Card Integration COMPLETE**: LLM-extracted entities now visible in Inbox detail view
  - Card displays between header and evidence sections
  - Collapsible sections for people, topics, facts, implications, actions
  - "Add Contact" buttons for newly extracted people (opens Contacts.app)
  - Badge shows "On-Device LLM" vs "Heuristic" analysis method

**Current Limitations (Enhancement Opportunities):**
- Add Contact pre-fill: Currently opens Contacts.app but doesn't pre-populate fields (needs CNContact integration)
- Email extraction: Extracted people don't have email addresses yet (LLM doesn't extract emails)
- Multi-word names: Heuristic extraction can struggle with "William Smith" (only catches first name)
- Note text visibility: Full note content only visible in evidence section (no direct link to note detail)

---

## 6) Recent Developments & Roadmap

### Phase 6: Smart Suggestions & Real-World Testing (COMPLETE - Feb 8, 2026)

**Completed:**
- [x] **Smart Suggestion System** - Comprehensive one-click workflow
  - `NoteEvidenceFactory.generateProposedLinks()` - Auto-detects family members from LLM analysis
  - `SuggestionActions` data models - Structured actions (contact updates, notes, messages)
  - `InboxDetailSections.applyAllSuggestions()` - Batch execution with proper actor isolation
  - Life event detection (birth, promotions, bonuses)
  - Pre-filled message templates for congratulations
- [x] **Contact Notes Preparation** - Ready for Apple entitlement
  - `hasNotesEntitlement` feature flag in ContactSyncService and PersonDetailSections
  - Note operations log to console when flag is false
  - Complete write/read infrastructure ready (commented CNContactNoteKey)
  - Documentation: NOTES_ENTITLEMENT_SETUP.md
- [x] **Fixture System Overhaul** - Real-world integration testing
  - Clear all SwiftData on each run
  - Import from SAM group only (respects architectural boundary)
  - Create realistic IUL product ($30K initial, $8K annual) with Coverage record
  - Create note about William's birth with life insurance requests
  - Let SAM's pipeline analyze and generate suggestions automatically
  - Full Swift 6 async/await compliance
  - Documentation: NEW_FIXTURE_APPROACH.md, FIXTURE_TESTING_GUIDE.md
- [x] **Swift 6 Concurrency Compliance** - Full strict concurrency mode
  - ContactSyncService: Removed `@MainActor` from class, read methods thread-safe
  - Write methods properly isolated to `@MainActor`
  - Explicit CNKeyDescriptor type casts throughout
  - Added CNContactFormatter descriptor for proper name formatting
  - PersonDetailView: nonisolated static methods for background access
  - Documentation: SWIFT6_CONCURRENCY_FIXES.md
- [x] **ContactSyncService.addRelationship()** - Generic method for any relationship type
  - Replaced specific methods (addSon, addDaughter) with unified addRelationship
  - Supports any CNContact relationship label
  - Convenience addChild method for common case

**Known Issues:**
- SmartSuggestionCard designed but not yet integrated (using AnalysisArtifactCard currently)
- SwiftData fault resolution warnings when accessing @Model objects outside context
- Notes entitlement pending Apple approval (~1 week estimated)

**Recently Resolved (Feb 8, 2026):**
- ✅ Swift 6 strict concurrency errors in FixtureSeeder and app initialization
- ✅ FixtureSeeder importing all contacts instead of SAM group only
- ✅ Invalid ModelContext.reset() API call
- ✅ Async/await structure throughout fixture and development tools

### Phase 7: Priority Work (NEXT)

**Immediate (This Week):**
1. **Complete Smart Suggestion Integration**
   - Replace AnalysisArtifactCard with SmartSuggestionCard in NoteArtifactDisplay
   - Test complete workflow: Harvey note → William suggestion → Apply → Contacts updated
   - Add message sending integration
2. **Test Real-World Fixture**
   - Add Harvey Snodgrass to Contacts.app
   - Run fixture and verify complete pipeline
   - Document issues and refine
3. **Submit Notes Entitlement Request**
   - Document business justification for Apple review
   - Prepare for ~1 week approval timeline

**Next (Week 2):**
1. **Product Display Implementation**
   - Product list view in navigation
   - Product detail view with policy information
   - Link from person detail to their products
   - Display Harvey's IUL in fixture test
2. **SwiftData Fault Prevention**
   - Audit all @Model object passing to views
   - Ensure properties accessed in context
   - Consider value type wrappers for display models

### Phase 8: Enhanced Integrations (Future)

1. **Mail Integration**
   - Observe Mail.app for interaction history per contact
   - Surface recent email threads in person detail view
   - "Draft Email" action that opens Mail.app with pre-filled recipient
   - Parse email metadata into Evidence items
2. **Calendar Deep Integration**
   - Two-way sync: Create calendar events from SAM
   - "Schedule Meeting" action opens Calendar.app with attendees pre-filled
   - Show upcoming meetings in person/context detail view
   - Meeting prep assistant (surfaces relevant insights before meetings)
3. **Contacts Enrichment**
   - Write SAM metadata back to Contacts notes field (optional, user-controlled)
   - "Open in Contacts" quick action
   - Photo sync improvements
   - Birthday/anniversary reminders

### Phase 6: AI Assistant (Cognitive Layer)
**Goal:** Introduce assistive AI that feels like a thoughtful junior partner
1. **Interaction Analysis**
   - Analyze meeting transcripts (Zoom integration placeholder)
   - Extract action items and commitments
   - Detect sentiment and relationship health signals
   - Generate meeting summaries
2. **Proactive Recommendations**
   - "You haven't connected with [Person] in 45 days" nudges
   - Suggest follow-up actions based on evidence patterns
   - Highlight time-sensitive opportunities
   - Best practice coaching (WFG compliance-aware)
3. **Communication Drafting**
   - Draft follow-up emails based on meeting context
   - Suggest talking points for upcoming meetings
   - Template library for common interactions
   - Always require explicit user approval before sending
4. **Natural Language Interface**
   - Quick add: "Remind me to follow up with John next Tuesday"
   - Search by intent: "Show me everyone I need to call this week"
   - Summarization: "What happened with the Smith household last quarter?"

### Phase 7: Compliance & Data Integrity
**Goal:** Build trust through transparency and safety mechanisms
1. **Change History & Undo**
   - Implement 30-day change history for relationships and metadata
   - Visual timeline of changes per person/context
   - Multi-level undo/redo (persistent across sessions)
   - Export change log for compliance audits
2. **Data Export & Portability**
   - CSV/JSON export for people, contexts, and interactions
   - Integration with WFG reporting systems
   - "Share Person" creates shareable summary PDF
3. **Privacy Controls**
   - Granular permission management (which calendars/contact groups to observe)
   - Data retention policies (configurable auto-delete old evidence)
   - Audit log of AI recommendations and user actions

### Phase 8: iOS Companion App
**Goal:** Lightweight mobile experience for on-the-go relationship management
1. **Core Views**
   - Today view: Upcoming meetings + follow-up reminders
   - Quick person lookup
   - Evidence review and triage (swipe to accept/dismiss)
   - Awareness dashboard
2. **Mobile-Specific Features**
   - Call integration (tap to call from person detail)
   - Location-based reminders ("Call Sarah when you arrive at office")
   - Voice notes as evidence items
   - Share extension (capture emails/messages as evidence)
3. **Sync Strategy**
   - CloudKit sync between macOS and iOS
   - Conflict resolution for offline edits
   - Local-first architecture with opportunistic sync

---

## 7) UX Guardrails (Stay Native)
Align with native macOS patterns and Apple HIG expectations. Phase 4 refinements include search/filter chips, organized toolbars, and comprehensive keyboard shortcuts.

---

## 8) Technical Debt & Polish
1. **Remaining Concurrency Warnings (deferred)**
   - Address DevLogStore.shared ambiguity and actor isolation issues
   - Full Swift 6 strict concurrency compliance
   - Note: Functional as-is; low priority
2. **Performance Optimization**
   - Profile and optimize SwiftData queries for large datasets (1000+ people)
   - Background indexing for search
   - Lazy loading for detail views
3. **Accessibility Audit**
   - Full VoiceOver support
   - Dynamic Type at all text scales
   - Keyboard-only navigation testing
   - Reduced Motion respect
4. **Design System**
   - Consistent spacing, typography, and color tokens
   - Reusable component library
   - Light/Dark mode refinement
   - SF Symbols usage audit

---

## 9) Non-Negotiables
- AI suggestions require explicit user approval; no autonomous actions.
- All permission prompts originate from Settings; never surprise the user.
- Maintain data integrity and user trust above feature velocity.
