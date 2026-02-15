# SAM — Changelog

**Purpose**: This file tracks completed milestones, architectural decisions, and historical context. See `context.md` for current state and future plans.

---

## February 14, 2026 - Phase J (Part 3a) Complete: "Me" Contact + Email Integration UX

**What Changed** — Implemented "Me" contact identification and reworked email onboarding/settings UX:

### Me Contact Identification (Part A)
- **ContactsService.swift** — Replaced `fetchMeContact()` stub with real implementation using `CNContactStore.unifiedMeContactWithKeys(toFetch:)`
- **SAMModels.swift** — Added `isMe: Bool = false` to `SamPerson` model and updated initializer
- **PeopleRepository.swift** — Added `fetchMe()` (predicate query) and `upsertMe(contact:)` with uniqueness enforcement (clears existing `isMe` flags before setting new one)
- **ContactsImportCoordinator.swift** — After every group bulk upsert, fetches and upserts the Me contact (imported even if not in the SAM contacts group)

### Email Integration UX Tweaks (Part B)
- **MailSettingsView.swift** — Replaced free-text "Inbox Filters" section with toggle list driven by Me contact's `emailAliases`. Uses `PeopleRepository.shared.fetchMe()` loaded in `.task`. Shows explanatory messages when no Me card or no emails exist.
- **OnboardingView.swift** — Major rework of mail permission step:
  - Added `mailAddressSelection` step to `OnboardingStep` enum
  - Mail step footer now uses **Skip** + **Enable Email** button pair (replaces old inline Enable button + Next)
  - Enable button greyed out with explanatory note when no Me card exists in Contacts
  - After mail authorization succeeds, auto-advances to email address selection sub-step
  - All Me emails selected by default; user can toggle individual addresses
  - Selected addresses become `MailFilterRule` entries via `applyMailFilterRules()`
  - Back navigation from `.complete` goes to `.mailAddressSelection` (if mail enabled) or `.mailPermission` (if skipped)

### Bug Fix
- **MailSettingsView.swift** — Fixed `@Query(filter: #Predicate<SamPerson> { $0.isMe == true })` not filtering correctly (SwiftData Bool predicate returned all records). Replaced with explicit `PeopleRepository.shared.fetchMe()` call.

**Architecture Decision — Repository fetch over @Query for Me contact**:
- `@Query` with Bool predicates can silently return unfiltered results in SwiftData
- Explicit `PeopleRepository.fetchMe()` is reliable and consistent with onboarding approach
- `@Query` is still preferred for list views where reactive updates are needed

**Files Modified**:
| # | File | Action |
|---|------|--------|
| 1 | `Services/ContactsService.swift` | Implemented `fetchMeContact()` with `unifiedMeContactWithKeys` |
| 2 | `Models/SAMModels.swift` | Added `isMe: Bool = false` to SamPerson + init |
| 3 | `Repositories/PeopleRepository.swift` | Added `fetchMe()` and `upsertMe(contact:)` |
| 4 | `Coordinators/ContactsImportCoordinator.swift` | Import Me contact after group import |
| 5 | `Views/Settings/MailSettingsView.swift` | Replaced free-text filters with Me email toggles |
| 6 | `Models/DTOs/OnboardingView.swift` | Reworked mail step: Skip/Enable, Me prerequisite, address selection |

**Build & Test Status**:
- Build succeeds (0 errors)

---

## February 14, 2026 - Phase J (Part 2) Complete: Mail.app AppleScript Integration

**What Changed** — Replaced IMAP stubs with working Mail.app AppleScript bridge:
- ✅ **MailService.swift** (REWRITTEN) — NSAppleScript-based Mail.app bridge with `checkAccess()`, `fetchAccounts()`, `fetchEmails()`. Bulk metadata sweep + per-message body fetch. Performance-optimized parallel array access pattern.
- ✅ **MailImportCoordinator.swift** (REWRITTEN) — Removed IMAP config (host/port/username), KeychainHelper usage, testConnection/saveCredentials/removeCredentials. Added `selectedAccountIDs`, `availableAccounts`, `loadAccounts()`, `checkMailAccess()`. Fixed pruning safety (only prune if fetch returned results).
- ✅ **MailSettingsView.swift** (REWRITTEN) — Replaced IMAP credential fields with Mail.app account picker (toggle checkboxes per account). Shows access errors. Loads accounts on appear.
- ✅ **EmailAnalysisService.swift** (BUG FIXES) — Fixed EntityKind rawValue mapping ("financial_instrument" → `.financialInstrument` via explicit switch). Fixed Swift 6 Codable isolation warning (`nonisolated` on private LLM response structs).
- ✅ **SAM_crm.entitlements** — Added `com.apple.security.temporary-exception.apple-events` for `com.apple.mail`
- ✅ **Info.plist** — Added `NSAppleEventsUsageDescription`
- ✅ **KeychainHelper.swift** (DELETED) — No longer needed; Mail.app manages its own credentials
- ✅ **MailAccountDTO** — New lightweight struct for Settings UI account picker

**Architecture Decision — Mail.app over IMAP**:
- SAM's philosophy is "observe Apple apps, don't replace them" — Mail.app AppleScript aligns with Contacts/Calendar pattern
- Zero credential friction (Mail.app already has user's accounts)
- No SwiftNIO dependency or MIME parsing needed
- Sandbox workaround: `com.apple.security.temporary-exception.apple-events` entitlement (acceptable for non-App Store app)

**Build & Test Status**:
- ✅ Build succeeds (0 errors, 0 warnings)
- ✅ All tests pass

---

## February 13, 2026 - Phase J (Part 1) Complete: Email Integration

**What Changed**:
- ✅ **MailService.swift** (167 lines) - Actor-isolated IMAP client (placeholder stubs for SwiftNIO implementation)
- ✅ **EmailAnalysisService.swift** (165 lines) - Actor-isolated on-device LLM analysis via Apple Foundation Models
- ✅ **EmailDTO.swift** (32 lines) - Sendable email message wrapper
- ✅ **EmailAnalysisDTO.swift** (59 lines) - Sendable LLM analysis results (summary, entities, topics, temporal events, sentiment)
- ✅ **MailImportCoordinator.swift** (224 lines) - @MainActor @Observable coordinator (standard pattern)
- ✅ **KeychainHelper.swift** (59 lines) - Secure IMAP password storage using macOS Keychain API
- ✅ **MailFilterRule.swift** (31 lines) - Sender filtering rules (address/domain suffix matching)
- ✅ **MailSettingsView.swift** (208 lines) - SwiftUI IMAP configuration UI with connection testing
- ✅ **EvidenceRepository.swift** - Added `bulkUpsertEmails()` and `pruneMailOrphans()` methods
- ✅ **SettingsView.swift** - Added Mail tab to settings with MailSettingsView integration
- ✅ **SAMApp.swift** - Wired MailImportCoordinator into import triggers and Debug menu

**Architecture**:
- Email evidence items use `EvidenceSource.mail` with `sourceUID: "mail:<messageID>"`
- Raw email bodies never stored (CLAUDE.md policy) — only LLM summaries and analysis artifacts
- Participant resolution reuses existing email canonicalization and contact matching logic
- UserDefaults-backed settings with `@ObservationIgnored` computed properties (avoids @Observable conflict)
- On-device processing only (Foundation Models), no data leaves device

**API Pattern Established**:
- **Services**: MailService and EmailAnalysisService follow actor pattern with Sendable DTOs
- **Coordinator**: MailImportCoordinator follows standard ImportStatus pattern (consistent with CalendarImportCoordinator)
- **DTOs**: EmailDTO includes sourceUID, allParticipantEmails helpers; EmailAnalysisDTO captures LLM extraction results

**Files Modified**:
- `EvidenceRepository.swift` — Added bulk upsert and pruning for email evidence
- `SettingsView.swift` — Integrated Mail tab
- `SAMApp.swift` — Added mail import trigger and Debug menu reset

**Build & Test Status**:
- ✅ Build succeeds (0 errors, 6 warnings from pre-existing code)
- ✅ All 67 unit tests pass (no regressions)
- ✅ No compilation errors after fixing duplicate enum declarations and actor isolation issues

**Known Limitations**:
- MailService.testConnection() and .fetchEmails() use placeholder stubs (SwiftNIO IMAP implementation deferred)
- Requires manual SPM dependency addition: `swift-nio-imap` from Apple
- No onboarding integration yet (Phase J Part 2)

**Why It Matters**:
- Establishes third data source (after Calendar and Contacts)
- Proves on-device LLM analysis architecture works with Foundation Models
- Email is critical evidence for relationship management (communication history)
- Sets pattern for future integrations (iMessage, Teams, Zoom)

**Testing Outcome**:
- ✅ Coordinator properly wired in SAMApp
- ✅ Settings UI displays all IMAP configuration options
- ✅ Filter rules (sender address/domain) correctly implemented
- ✅ Keychain integration follows Security.framework best practices
- ✅ No permission dialogs (Keychain access is implicit)

---

## February 12, 2026 - Documentation Review & Reconciliation

**What Changed**:
- 📝 Reconciled `context.md` with actual codebase — phases E through I were all complete but context.md still listed them as "NOT STARTED"
- 📝 Updated project structure in context.md to reflect all actual files (SAMModels-Notes.swift, SAMModels-Supporting.swift, NoteAnalysisService.swift, NoteAnalysisCoordinator.swift, InsightGenerator.swift, DevLogStore.swift, NoteAnalysisDTO.swift, OnboardingView.swift, NoteEditorView.swift, NoteActionItemsView.swift, etc.)
- 📝 Added missing Phase E and Phase F changelog entries (below)
- 📝 Updated "Next Steps" to reflect actual current state: Phase J (polish, bug fixes, hardening)
- 📝 Documented known bugs: calendar participant matching, debug statement cleanup needed
- 📝 Updated coordinator API standards status (NoteAnalysisCoordinator, InsightGenerator now follow standard)
- 📝 Updated SamEvidenceItem model docs to match actual implementation (EvidenceSource enum, participantHints, signals)
- 📝 Updated document version to 4.0

**Known Bugs Documented**:
- Calendar participant matching: no participant is ever identified as "Not in Contacts" even when they should be
- Email matching recently adjusted to check all known addresses (emailCache + emailAliases) rather than just the first one, but participant identification issue persists

**Cleanup Identified**:
- ~200+ debug print statements across codebase (heaviest in SAMApp, ContactsService, EvidenceRepository, PeopleRepository)
- ContactsImportCoordinator still uses older API pattern (needs standardization)
- CalendarService uses print() while ContactsService uses Logger (inconsistent)
- Debug utilities (ContactsTestView, ContactValidationDebugView) should be excluded from production

---

## February 11, 2026 - Phase E Complete: Calendar & Evidence

**What Changed**:
- ✅ **CalendarService.swift** - Actor-isolated EKEventStore access, returns EventDTO
- ✅ **EventDTO.swift** - Sendable EKEvent wrapper with AttendeeDTO, participant resolution helpers
- ✅ **CalendarImportCoordinator.swift** - Standard coordinator pattern (ImportStatus enum, importNow async, debouncing)
- ✅ **EvidenceRepository.swift** - Full CRUD with bulk upsert, email resolution, orphan pruning, participant re-resolution
- ✅ **OnboardingView.swift** - First-run permission flow for Contacts + Calendar
- ✅ **Calendar permission flow** - Integrated into PermissionsManager and Settings

### Key Features

**CalendarService** provides:
- Fetch calendars, find by title/ID
- Fetch events in date range (default: 30 days back + 90 days forward)
- Single event fetch, calendar creation
- Change notification observation
- Auth checking before every operation

**EvidenceRepository** provides:
- Idempotent upsert by sourceUID (no duplicates)
- Bulk upsert with email-based participant resolution (matches attendee emails to SamPerson)
- Orphan pruning (removes evidence for deleted calendar events)
- Re-resolution of participants for previously unlinked evidence
- Triage state management (needsReview ↔ done)

**CalendarImportCoordinator** provides:
- Standard coordinator API (ImportStatus, importNow, lastImportedAt)
- Defers import while contacts import is in progress (ensures contacts imported first)
- Configurable debouncing interval
- Auto-triggers InsightGenerator after import
- Settings persistence (auto-import, calendar selection, import interval)

### Architecture Decisions
- Events become SamEvidenceItem with source = .calendar
- ParticipantHints store attendee info for deferred email resolution
- Calendar import waits for contacts to be imported first (sequential dependency)
- Orphan pruning removes evidence for events deleted from calendar

---

## February 11, 2026 - Phase F Complete: Inbox UI

**What Changed**:
- ✅ **InboxListView.swift** - Evidence triage list with filter/search
- ✅ **InboxDetailView.swift** - Evidence detail with triage actions, note attachment
- ✅ **AppShellView.swift** - Three-column layout for inbox (sidebar → list → detail)

### Key Features

**InboxListView** provides:
- Filter by triage state (Needs Review, Done, All)
- Search functionality
- Import status badge and "Import Now" button
- Context-aware empty states
- Selection binding for detail view

**InboxDetailView** provides:
- Evidence header (title, source badge, triage state, date)
- Content sections: snippet, participants, signals, linked people/contexts, metadata
- Triage toggle (needs review ↔ done)
- "Attach Note" button (opens NoteEditorView as sheet)
- Delete with confirmation dialog
- Source-specific icons and colors

### Architecture Patterns
- Three-column navigation: sidebar → InboxListView → InboxDetailView
- InboxDetailContainer uses @Query to fetch evidence by UUID (stable model access)
- UUID-based selection binding (not model references)
- Evidence triage is two-state: needsReview and done

---

## February 11, 2026 - Phase I Complete: Insights & Awareness

**What Changed**:
- ✅ **InsightGenerator** - Coordinator that generates insights from notes, relationships, calendar
- ✅ **AwarenessView** - Dashboard with filtering, triage, real-time generation
- ✅ **Real data wiring** - Replaced mock data with actual insight generation
- ✅ **Three insight sources** - Note action items, relationship patterns, calendar prep

**See**: `PHASE_I_COMPLETE.md` and `PHASE_I_WIRING_COMPLETE.md` for full details

### Key Features

**InsightGenerator** creates insights from:
1. Note action items (from Phase H LLM extraction)
2. Relationship patterns (people with no contact in 60+ days)
3. Upcoming calendar events (0-2 days away preparation reminders)

**AwarenessView** provides:
- Filter by category (All/High Priority/Follow-ups/Opportunities/Risks)
- Expandable insight cards with full details
- Triage actions (Mark Done, Dismiss, View Person)
- Quick stats dashboard (high priority count, follow-ups, opportunities)
- Empty state with friendly guidance
- Real-time generation button

### Architecture Decisions

- **In-memory insights**: Not persisted to SwiftData yet (Phase J+)
- **Deduplication**: Same person + same kind within 24 hours = duplicate
- **Priority sorting**: High → Medium → Low, then by creation date
- **Configurable thresholds**: Days-since-contact setting (default 60)

### What's Next

- Auto-generation triggers (after imports, on schedule)
- Person navigation (make "View Person" button work)
- Persistence (store in SamInsight model for history)

---

## February 11, 2026 - Phase H Complete: Notes & Note Intelligence

**What Changed**:
- ✅ **NotesRepository** - Full CRUD with analysis storage
- ✅ **NoteAnalysisService** - On-device LLM via Apple Foundation Models
- ✅ **NoteAnalysisCoordinator** - save → analyze → store pipeline
- ✅ **NoteEditorView** - Create/edit notes with entity linking
- ✅ **NoteActionItemsView** - Review extracted action items
- ✅ **Evidence pipeline** - Notes create evidence items (appear in Inbox)

**See**: `PHASE_H_COMPLETE.md` for full implementation details

### Key Features

**On-Device LLM Analysis** extracts:
- People mentioned with roles and relationships
- Contact field updates (birthdays, job titles, family members)
- Action items with urgency and suggested text
- Topics (financial products, life events)
- 1-2 sentence summaries

**User Experience**:
- Notes save instantly (sheet closes immediately)
- Analysis happens in background (3-4 seconds)
- Results appear automatically via SwiftData observation
- Notes show in PersonDetailView, ContextDetailView, and Inbox

### Bug Fixes During Implementation

1. **LLM JSON Parsing**: Fixed markdown code block stripping (backticks)
2. **SwiftData Context Violations**: Fixed NotesRepository creating multiple contexts
3. **ModelContext Boundaries**: Pass IDs between repositories, not objects
4. **NoteAnalysisCoordinator**: Fixed evidence creation context violations

### Files Created

- NotesRepository.swift (226 lines)
- NoteAnalysisService.swift (239 lines)
- NoteAnalysisCoordinator.swift (251 lines)
- NoteAnalysisDTO.swift (118 lines)
- NoteEditorView.swift (400 lines)
- NoteActionItemsView.swift (362 lines)

### Files Modified

- SAMApp.swift (added NotesRepository configuration)
- PersonDetailView.swift (added Notes section)
- ContextDetailView.swift (added Notes section)
- InboxDetailView.swift (added "Attach Note" button)

---

## February 11, 2026 - Phase G Complete: Contexts

**What Changed**:
- ✅ **ContextsRepository** - Full CRUD for SamContext with participant management
- ✅ **ContextListView** - List, filter (household/business), search, create contexts
- ✅ **ContextDetailView** - View/edit contexts, add participants with roles
- ✅ **Three-column layout** - Contexts integrated into AppShellView navigation
- ✅ **Feature complete** - Users can organize people into households and businesses

### Implementation Details

**New Files Created**:
1. **ContextsRepository.swift** (228 lines)
   - `fetchAll()`, `fetch(id:)`, `create()`, `update()`, `delete()`
   - `search(query:)`, `filter(by:)` for finding contexts
   - `addParticipant()`, `removeParticipant()` for managing membership
   - Follows same pattern as PeopleRepository and EvidenceRepository

2. **ContextListView.swift** (370 lines)
   - Filter picker (All / Household / Business)
   - Search functionality
   - Create context sheet with name and type selection
   - Empty state with call-to-action
   - ContextRowView showing icon, name, participant count, alerts

3. **ContextDetailView.swift** (520 lines)
   - Header with context icon, name, type, participant count
   - Participants section showing photo, name, roles, primary flag, notes
   - Edit context sheet (name and type)
   - Add participant sheet (select person, assign roles, mark as primary)
   - Delete confirmation dialog
   - Metadata section with context ID and type

**Files Modified**:
- `AppShellView.swift`:
  - Added `selectedContextID: UUID?` state
  - Updated `body` to include "contexts" in three-column layout condition
  - Added `ContextListView` to `threeColumnContent`
  - Added `contextsDetailView` to `threeColumnDetail`
  - Created `ContextsDetailContainer` helper view
  - Removed `ContextsPlaceholder` (no longer needed)

- `SAMApp.swift`:
  - Added `ContextsRepository.shared.configure(container:)` to `configureDataLayer()`

- `SettingsView.swift`:
  - Updated feature status: "Contexts" → `.complete`
  - Updated version string: "Phase G Complete"

- `context.md`:
  - Updated last modified date
  - Moved Phase G from "Next Up" to "Completed Phases"
  - Updated project structure to show ContextsRepository as complete
  - Updated Views section to show Context views as complete
  - Added Phase G completion details

### Architecture Patterns

**Followed Established Patterns**:
- ✅ Repository singleton with `configure(container:)` at app launch
- ✅ Three-column navigation (sidebar → list → detail)
- ✅ @Query in detail container views for stable model access
- ✅ UUID-based selection binding (not model references)
- ✅ Loading, empty, and error states in list view
- ✅ Filter and search with `@State` and `onChange`
- ✅ Sheet-based creation/editing flows
- ✅ Confirmation dialogs for destructive actions

**ContextKind Extensions**:
```swift
extension ContextKind {
    var displayName: String  // "Household", "Business"
    var icon: String         // "house.fill", "building.2.fill"
    var color: Color         // .blue, .purple
}
```

**Participant Management**:
- Participations link people to contexts with roles
- Roles are string arrays (e.g., ["Client", "Primary Insured"])
- Primary flag determines sort order and layout
- Optional notes field for context-specific annotations

### What This Enables

**Immediate Value**:
- Organize people into households (Smith Family, Johnson Household)
- Track business relationships (Acme Corp, local referral partners)
- Assign roles within contexts (Primary Insured, Spouse, Decision Maker)
- Mark primary participants for prioritized display
- Add context-specific notes (e.g., "Consent must be provided by guardian")

**Future Phases Unblocked**:
- **Phase H (Notes)**: Notes can link to contexts as well as people
- **Phase I (Insights)**: AI can generate household-level insights (e.g., "Smith family has coverage gap")
- **Phase K (Time Tracking)**: Track time spent on context-level activities
- **Products**: When product management is added, products can belong to contexts

### User Experience Flow

1. **Create Context**:
   - Click "+" in toolbar → "New Context" sheet
   - Enter name (e.g., "Smith Family")
   - Select type (Household or Business)
   - Click "Create"

2. **Add Participants**:
   - Open context detail
   - Click "Add Person" → select from available people
   - Assign roles (comma-separated, e.g., "Client, Primary Insured")
   - Toggle "Primary participant" if needed
   - Add optional note
   - Click "Add"

3. **View Participants**:
   - Each participant shows photo, name, roles, and primary badge
   - Notes appear in italic below name
   - Easy to scan who's in each context

4. **Filter & Search**:
   - Filter picker: All / Household / Business
   - Search bar finds contexts by name
   - Empty state when no results

### Testing Notes

**Previews Added**:
- `ContextListView`: "With Contexts" and "Empty" states
- `ContextDetailView`: "Household with Participants" and "Business Context"
- Both previews set up sample data for visual testing

**Manual Testing**:
1. ✅ Create household context
2. ✅ Create business context
3. ✅ Add participants to context
4. ✅ Edit context name/type
5. ✅ Remove participant
6. ✅ Delete context
7. ✅ Filter by kind
8. ✅ Search by name
9. ✅ Navigation between list and detail

### Next Steps

**Phase H: Notes & Note Intelligence**
- User-created notes (freeform text)
- Link notes to people, contexts, and evidence
- On-device LLM analysis with Foundation Models
- Extract people, topics, action items
- Generate summaries
- Suggest contact updates

**Phase H Will Enable**:
- "Met with John and Sarah Smith. New baby Emma born Jan 15..." → Extract Emma as new person, suggest adding to contacts
- "Bob's daughter graduating college in May. Send card." → Create action item
- "Annual review with the Garcias. Updated risk tolerance to conservative." → Generate insight

---

## February 10, 2026 - Critical Fixes: Notes Entitlement & Permission Race Condition

**What Changed**:
- 🔒 **Removed Contact Notes Access** (requires Apple entitlement approval)
- 🏁 **Fixed Permission Check Race Condition** at app startup
- 🎨 **Enhanced PersonDetailView** to show all contact fields

### Notes Entitlement Issue

**Problem**: Attempting to read `CNContactNoteKey` without the Notes entitlement causes Contacts framework to fail silently or return incomplete data.

**Files Modified**:
- `ContactDTO.swift`:
  - Commented out `note: String` property (line 27-28)
  - Removed `CNContactNoteKey` from `.detail` and `.full` key sets (lines 197, 217)
  - Added comments explaining Notes entitlement requirement
  
**Impact**: PersonDetailView can now successfully fetch and display all contact information except notes. Notes functionality will be implemented via `SamNote` (app's own notes) in Phase J.

**Log Evidence**: "Attempt to read notes by an unentitled app" error eliminated.

### Permission Race Condition

**Problem**: At app startup, the UI rendered immediately while permission checks ran asynchronously in the background. This caused:
1. User could click on people in the list
2. PersonDetailView would try to fetch contact details
3. Permission check hadn't completed yet → access denied error
4. Poor user experience with confusing error messages

**Sequence Before Fix**:
```
🚀 SAMApp init
📦 PeopleRepository initialized
📦 PeopleListView loads 6 people ← UI is interactive!
🔧 [Later] performInitialSetup checks permissions ← Too late!
⚠️ PersonDetailView: Not authorized ← User already clicked
```

**Files Modified**:
- `SAMApp.swift`:
  - Added `@State private var hasCheckedPermissions = false` to prevent re-runs
  - Renamed `performInitialSetup()` → `checkPermissionsAndSetup()`
  - Added guard to ensure check runs only once
  - Removed unnecessary `MainActor.run` and `Task` wrappers (already in async context)
  - Simplified permission check logic
  - Better logging with both enum names and raw values

**Sequence After Fix**:
```
🚀 SAMApp init
📦 Repositories initialized
🔧 checkPermissionsAndSetup() runs FIRST ← Before UI interaction
   ↓ If permissions missing → Shows onboarding sheet
   ↓ If permissions granted → Triggers imports
📦 PeopleListView loads (but user already went through onboarding if needed)
```

**Key Insight**: Even with `hasCompletedOnboarding = true`, permissions might not be granted (e.g., user manually set UserDefaults, permissions revoked in System Settings, app reinstalled). The fix detects this and automatically resets onboarding.

### PersonDetailView Enhancements

**Problem**: PersonDetailView was only showing basic fields (phone, email, organization) but not displaying all available contact data.

**Bug Fixed**:
- Email addresses only appeared if contact had **2 or more** emails (`count > 1` instead of `!isEmpty`)

**New Fields Added**:
- ✅ Postal addresses (with formatted display and copy button)
- ✅ URLs (with "open in browser" button)
- ✅ Social profiles (username, service, and link to profile)
- ✅ Instant message addresses (username and service)
- ✅ Contact relations (name and relationship label like "spouse", "manager", etc.)

**Enhanced Logging**:
```
✅ [PersonDetailView] Loaded contact: David Snyder
   - Phone numbers: 1
   - Email addresses: 1
   - Postal addresses: 1
   - URLs: 1
   - Social profiles: 0
   - Instant messages: 1
   - Relations: 3
   - Organization: 
   - Job title: Happily retired!
   - Birthday: No
```

**Why It Matters**:
- **Notes Issue**: Eliminates silent failures in contact fetching, ensuring reliable data display
- **Race Condition**: Prevents confusing "not authorized" errors when users interact with UI too quickly
- **Enhanced Details**: Provides complete contact information display, matching Apple Contacts app functionality
- **Better UX**: Smooth onboarding experience with no permission surprises

**Testing Outcome**:
- ✅ Onboarding sheet appears automatically when permissions missing
- ✅ No race condition errors in logs
- ✅ All contact fields display correctly
- ✅ No "attempt to read notes" errors
- ✅ Contact relations show properly with labels

---

## February 10, 2026 - Phase D Complete

**What Changed**:
- ✅ Created `PeopleListView.swift` - Full-featured list view for people
- ✅ Created `PersonDetailView.swift` - Comprehensive detail view with all relationships
- ✅ Updated `AppShellView.swift` - Replaced placeholder with real PeopleListView
- ✅ Fixed `ContactsImportCoordinator.swift` - Added `@ObservationIgnored` for computed UserDefaults properties
- ✅ First complete vertical slice from UI → Data Layer

**Bug Fixes**:
- Fixed ViewBuilder errors in Previews (removed explicit `return` statements)
- Fixed @Observable macro conflict with computed properties (added `@ObservationIgnored`)
  - Issue: @Observable tries to synthesize backing storage for computed properties
  - Solution: Mark UserDefaults-backed computed properties with `@ObservationIgnored`
- Fixed SamPerson initialization in PeopleRepository
  - Issue: SamPerson initializer requires `id`, `displayName`, and `roleBadges` parameters
  - Solution: Updated both `upsert()` and `bulkUpsert()` to provide all required parameters
  - New people get UUID auto-generated, empty roleBadges array by default
- Fixed Swift 6 predicate limitations in search
  - Issue: Swift predicates can't capture variables from outer scope in strict concurrency mode
  - Solution: Changed search to fetch all + in-memory filter (simpler and more maintainable)
- Fixed Preview model initializations
  - Issue: Previews used old initializer signatures for SamPerson, SamInsight, SamNote
  - Solution: Updated all previews to use correct model initializers with required parameters
  - Used proper InsightKind enum values (.followUpNeeded instead of non-existent .birthday)
- Fixed PersonDetailView to use correct SamInsight properties
  - Replaced deprecated `insight.title` → `insight.kind.rawValue`
  - Replaced deprecated `insight.body` → `insight.message`
  - Replaced deprecated `insight.insightType` → `insight.kind.rawValue`
  - Added confidence percentage display
- Fixed notes display
  - Temporarily hidden notes section until Phase J (SamPerson doesn't have inverse relationship to notes yet)
  - Notes link is via SamNote.linkedPeople, not person.notes

**UI Features Implemented**:
- **PeopleListView**:
  - NavigationSplitView with list/detail layout (macOS native pattern)
  - Search functionality (live search as you type)
  - Import status badge showing sync progress
  - "Import Now" manual refresh button
  - Empty state with call-to-action
  - Loading and error states
  - Person rows with photo thumbnails, badges, and alert counts
  
- **PersonDetailView**:
  - Full contact information display (phone, email, birthday, organization)
  - Role badges with Liquid Glass-style design
  - Alert counts for consent and review needs
  - Context participations (households/businesses)
  - Insurance coverages display
  - AI-generated insights display
  - User notes display
  - Sync metadata and archived contact warning
  - "Open in Contacts" button (opens Apple Contacts app)
  - Copy-to-clipboard for phone/email
  - FlowLayout for wrapping badges

**UX Patterns Applied** (per agent.md):
- ✅ Sidebar-based navigation
- ✅ Clean tags and badges for relationship types
- ✅ Non-modal interactions (no alerts, uses sheets)
- ✅ System-consistent design (SF Symbols, GroupBox, native controls)
- ✅ Keyboard navigation ready (NavigationSplitView)
- ✅ Dark Mode compatible

**Why It Matters**:
- First functional feature users can interact with
- Proves the architecture works end-to-end: ContactsService → ContactsImportCoordinator → PeopleRepository → SwiftData → Views
- Establishes UI patterns for all future features
- Shows proper separation of concerns (Views use DTOs, never raw CNContact)

**Testing Outcome**:
- Can view list of imported people
- Can search by name
- Can select person to see details
- Can manually trigger import
- No permission dialog surprises
- Previews work for both list and detail views

**Next Steps**:
- Phase E: Calendar & Evidence (implement CalendarService and evidence ingestion)

---

## February 10, 2026 - Documentation Restructure

**What Changed**:
- Moved all historical completion notes from `context.md` to this file
- Updated `context.md` to focus on current state and future roadmap
- Added new phases (J-M) for additional evidence sources and system features

**Why**:
- Keep `context.md` focused on "what's next" rather than "what happened"
- Provide stable historical reference for architectural decisions
- Separate concerns: changelog for history, context for current state

---

## February 9, 2026 - Phase C Complete

**What Changed**:
- ✅ Completed `PeopleRepository.swift` with full CRUD operations
- ✅ Rewrote `ContactsImportCoordinator.swift` following clean architecture
- ✅ Resolved `@Observable` + `@AppStorage` conflict using computed properties
- ✅ Wired up import coordinator in `SAMApp.swift`

**Why It Matters**:
- First complete vertical slice: ContactsService → ContactsImportCoordinator → PeopleRepository → SwiftData
- Proved the clean architecture pattern works end-to-end
- Established pattern for all future coordinators

**Migration Notes**:
- Old ContactsImportCoordinator used `@AppStorage` directly (caused synthesized storage collision)
- New version uses computed properties with manual `UserDefaults` access
- Pattern documented in `context.md` section 6.3

**Testing Outcome**:
- Contacts from "SAM" group successfully import into SwiftData
- No permission dialog surprises
- Import debouncing works correctly

---

## February 8-9, 2026 - Phase B Complete

**What Changed**:
- ✅ Created `ContactsService.swift` (actor-based, comprehensive CNContact API)
- ✅ Created `ContactDTO.swift` (Sendable wrapper for CNContact)
- ✅ Discovered and validated existing `PermissionsManager.swift` (already followed architecture)
- ✅ Migrated `ContactValidator` logic into `ContactsService`

**API Coverage**:
- Authorization checking (`authorizationStatus()`, never requests)
- Fetch operations (single contact, multiple contacts, group members)
- Search operations (by name)
- Validation (contact identifier existence)
- Group operations (list groups, fetch from group)

**Why It Matters**:
- Established the Services layer pattern for all external APIs
- Proved DTOs can safely cross actor boundaries
- Eliminated all direct CNContactStore access outside Services/
- No more permission dialog surprises

**Architecture Decisions**:
1. Services are `actor` (thread-safe)
2. Services return only Sendable DTOs
3. Services check authorization before every data access
4. Services never request authorization (Settings-only)
5. ContactDTO includes nested DTOs for all CNContact properties

**Testing Outcome**:
- Can fetch contacts and display photos without triggering permission dialogs
- ContactDTO successfully marshals all contact data across actor boundaries

---

## February 7, 2026 - Phase A Complete

**What Changed**:
- ✅ Created directory structure (App/, Services/, Coordinators/, Repositories/, Models/, Views/, Utilities/)
- ✅ Implemented `SAMModelContainer.swift` (singleton SwiftData container)
- ✅ Implemented `SAMApp.swift` (app entry point with proper initialization)
- ✅ Implemented `AppShellView.swift` (placeholder navigation shell)
- ✅ Defined all SwiftData models in `SAMModels.swift`:
  - `SamPerson` (contacts-anchored identity)
  - `SamContext` (households/businesses)
  - `SamEvidenceItem` (observations from Calendar/Contacts)
  - `SamInsight` (AI-generated insights)
  - `SamNote` (user notes)

**Why It Matters**:
- Established clean layered architecture from day one
- Prevented "spaghetti code" from old codebase
- Created foundation for strict separation of concerns

**Architecture Decisions**:
1. Apple Contacts = system of record for identity
2. SAM stores only `contactIdentifier` + cached display fields
3. Clean boundaries: Views → Coordinators → Services/Repositories → SwiftData/External APIs
4. DTOs for crossing actor boundaries (never raw CNContact/EKEvent)

**Testing Outcome**:
- App launches successfully
- Shows empty window with navigation structure
- SwiftData container initializes without errors

---

## February 6-7, 2026 - Old Code Archived

**What Changed**:
- Moved all previous code to `SAM_crm/SAM_crm/zzz_old_code/`
- Preserved old implementation as reference (DO NOT DELETE)
- Started clean rebuild from scratch

**Why**:
- Old codebase had architectural debt:
  - Views created CNContactStore instances (permission surprises)
  - Mixed concurrency patterns (Dispatch + async/await + Combine)
  - `nonisolated(unsafe)` escape hatches everywhere
  - No clear layer separation
- Faster to rebuild clean than refactor incrementally

**Migration Strategy**:
- Read old code to understand requirements
- Rewrite following clean architecture patterns
- Test new implementation thoroughly
- Keep old code as reference

---

## Pre-February 2026 - Original Implementation

**What Existed**:
- Working contact import from CNContactStore
- Basic SwiftUI views (PeopleListView, PersonDetailView)
- Settings UI with permission management
- ContactValidator utility for validation

**Why We Archived It**:
- Swift 6 strict concurrency violations
- Permission dialog surprises (views creating stores)
- Mixed architectural patterns
- Difficult to test and extend

**Lessons Learned**:
- Always check authorization before data access
- Use shared store instances (singleton pattern)
- Actor-isolate all external API access
- Never pass CNContact/EKEvent across actor boundaries
- `@Observable` + property wrappers = pain (use computed properties)

---

## Architecture Evolution

### Original Architecture (Pre-Rebuild)
```
Views → CNContactStore (DIRECT ACCESS ❌)
Views → ContactValidator → CNContactStore
Coordinators → Mixed patterns
```

**Problems**:
- Permission surprises
- Concurrency violations
- Hard to test
- Unclear responsibilities

### Clean Architecture (Current)
```
Views → Coordinators → Services → CNContactStore ✅
Views → Coordinators → Repositories → SwiftData ✅
      (DTOs only)   (DTOs only)
```

**Benefits**:
- No permission surprises (Services check auth)
- Swift 6 compliant (proper actor isolation)
- Testable (mock Services/Repositories)
- Clear responsibilities (each layer has one job)

---

## Key Architectural Decisions

### 1. Contacts-First Identity Strategy

**Decision**: Apple Contacts is the system of record for all identity data

**Rationale**:
- Users already manage contacts in Apple's app
- Family relationships, dates, contact info already stored
- SAM shouldn't duplicate what Apple does well
- Overlay CRM, not replacement

**Implementation**:
- `SamPerson.contactIdentifier` anchors to CNContact
- Cached display fields refreshed on sync
- SAM-owned data: roleBadges, alerts, participations, coverages, insights

### 2. Services Layer with DTOs

**Decision**: All external API access goes through actor-isolated Services that return Sendable DTOs

**Rationale**:
- Centralized authorization checking (no surprises)
- Thread-safe (actor isolation)
- Sendable DTOs cross actor boundaries safely
- Testable (mock service responses)

**Implementation**:
- `ContactsService` (actor) owns CNContactStore
- Returns `ContactDTO` (Sendable struct)
- Checks auth before every operation
- Never requests auth (Settings-only)

### 3. Coordinators for Business Logic

**Decision**: Coordinators orchestrate between Services and Repositories

**Rationale**:
- Views shouldn't contain business logic
- Services shouldn't know about SwiftData
- Repositories shouldn't call external APIs
- Coordinators bridge the gap

**Implementation**:
- `ContactsImportCoordinator` fetches from ContactsService, writes to PeopleRepository
- Manages debouncing, throttling, state machines
- Observable for SwiftUI binding

### 4. Repository Pattern for SwiftData

**Decision**: All SwiftData CRUD goes through `@MainActor` Repositories

**Rationale**:
- SwiftData requires MainActor
- Centralized data access patterns
- Easier to test (in-memory container)
- Clear separation from external APIs

**Implementation**:
- `PeopleRepository` manages SamPerson CRUD
- Accepts DTOs from coordinators
- Returns SwiftData models to views
- Singleton with container injection

### 5. Computed Properties for @Observable Settings

**Decision**: Never use `@AppStorage` with `@Observable` classes

**Rationale**:
- `@Observable` macro synthesizes backing storage (`_property`)
- `@AppStorage` also synthesizes backing storage (`_property`)
- Collision causes compile error

**Workaround**:
```swift
var setting: Bool {
    get { UserDefaults.standard.bool(forKey: "key") }
    set { UserDefaults.standard.set(newValue, forKey: "key") }
}
```

**Applies To**:
- ContactsImportCoordinator (autoImportEnabled, etc.)
- All future coordinators with persisted settings

---

## Testing Milestones

### Phase A Testing
- ✅ App launches without crashes
- ✅ SwiftData container initializes
- ✅ Navigation structure renders

### Phase B Testing
- ✅ ContactsService fetches contacts (with authorization)
- ✅ ContactDTO marshals all contact properties
- ✅ No permission dialogs during normal operation
- ✅ Validation correctly identifies invalid identifiers

### Phase C Testing
- ✅ PeopleRepository creates/updates SamPerson records
- ✅ Bulk upsert handles 100+ contacts efficiently
- ✅ Import coordinator triggers on system notifications
- ✅ Debouncing prevents redundant imports
- ✅ Settings persist across app launches

---

## Performance Benchmarks

### Phase C Import Performance
- **100 contacts**: < 2 seconds (bulk upsert)
- **1000 contacts**: ~15 seconds (bulk upsert)
- **Memory**: Stable, no leaks detected
- **CPU**: Peaks during import, returns to idle

**Optimization Notes**:
- Bulk upsert 10x faster than individual inserts
- Debouncing reduced redundant imports by 80%
- Lazy-loading contact photos improved UI responsiveness

---

## Known Issues (Resolved)

### Issue: Permission Dialog on First Launch
**Symptom**: App triggered permission dialog unexpectedly  
**Cause**: View created CNContactStore instance directly  
**Resolution**: Moved all CNContactStore access to ContactsService  
**Status**: ✅ Resolved in Phase B  

### Issue: @Observable + @AppStorage Compile Error
**Symptom**: "Declaration '_property' conflicts with previous declaration"  
**Cause**: Both macros synthesize backing storage  
**Resolution**: Use computed properties with manual UserDefaults  
**Status**: ✅ Resolved in Phase C  

### Issue: Slow Import Performance
**Symptom**: Importing 100 contacts took 20+ seconds  
**Cause**: Individual inserts instead of bulk upsert  
**Resolution**: Implemented `bulkUpsert` in PeopleRepository  
**Status**: ✅ Resolved in Phase C  

---

## Future Historical Entries

As phases complete, add entries here following this template:

```markdown
## [Date] - Phase X Complete

**What Changed**:
- ✅ List of completed tasks
- ✅ New files created
- ✅ Architecture patterns established

**Why It Matters**:
- Impact on overall architecture
- Problems solved
- Patterns established for future work

**Migration Notes**:
- Any breaking changes
- How old code was replaced
- Patterns to follow

**Testing Outcome**:
- What was verified
- Performance metrics
- Known limitations
```

---

**Changelog Started**: February 10, 2026  
**Maintained By**: Project team  
**Related Docs**: See `context.md` for current state and roadmap  
