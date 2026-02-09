# SAM – Changelog

A compact history of notable changes, fixes, and phases. For current architecture and guardrails, see context.md.

## 2026-02-08 – Phase 6: Smart Suggestions & Real-World Fixture Testing

### Smart Suggestion System
- **NoteEvidenceFactory enhancements:**
  - `generateProposedLinks()` auto-detects family members from `SamAnalysisArtifact.people`
  - Creates `ProposedLink` suggestions to add dependents (son/daughter/child) to parent's contact
  - Filters by `isFamily()` helper (supports son, daughter, child, spouse, etc.)
- **InboxDetailSections additions:**
  - `SuggestionActions`, `ContactUpdate`, `SuggestedMessage`, `LifeEvent` data models
  - `applyAllSuggestions()` method with proper Swift 6 actor isolation (MainActor.run for UI updates)
  - `openInContacts()` helper to launch Contacts.app via `addressbook://` URL scheme
- **SmartSuggestionCard designed** (not yet integrated):
  - Life event detection (birth, work promotions, bonuses)
  - Comprehensive action suggestions (add family, update notes, send messages)
  - Pre-filled congratulations message templates
  - One-click "Apply All" and "Apply & Edit" workflows

### Contact Notes Entitlement Preparation
- **Feature flag system:**
  - `hasNotesEntitlement = false` in both ContactSyncService and PersonDetailSections
  - When false: Note operations log to console instead of writing
  - When true (after Apple approval): Full read/write to `CNContact.note`
- **ContactSyncService.updateSummaryNote():**
  - Logs proposed note content with clear formatting
  - Appends to existing notes (never overwrites)
  - Ready to enable by flipping flag + uncommenting `CNContactNoteKey`
- **PersonDetailSections.SummaryNoteSection:**
  - Shows "Notes Access Pending" banner with explanation
  - "Suggest AI Update" button generates draft from artifact data
  - User approval sheet before any note changes
- **Documentation:** NOTES_ENTITLEMENT_SETUP.md with step-by-step enable instructions

### Fixture System Overhaul
- **New approach:** Real-world integration testing instead of fake data
  1. `clearAllData()` - Delete all SwiftData (people, contexts, products, notes, evidence, insights)
  2. `importHarveyFromContacts()` - Search for "Harvey Snodgrass" in user's Contacts.app
  3. `createHarveysIUL()` - Create Product ($30K initial, $8K annual premium)
  4. `createWilliamBirthNote()` - Realistic note about son's birth with life insurance requests
  5. Let SAM's pipeline analyze and generate suggestions automatically
- **Benefits:**
  - Tests complete end-to-end flow (Contacts → Notes → LLM → Evidence → Suggestions)
  - Avoids SwiftData fault resolution issues
  - Demonstrates real value proposition
- **Usage:** Settings → Backup → "Restore Developer Fixture" (requires Harvey in Contacts.app)
- **BackupTab.swift:** Updated to `await FixtureSeeder.seedIfNeeded()` (async)
- **Documentation:** NEW_FIXTURE_APPROACH.md, FIXTURE_TESTING_GUIDE.md

### Swift 6 Concurrency Compliance
- **ContactSyncService actor isolation fixes:**
  - Removed `@MainActor` from class (was blocking detached task access)
  - Made `shared` singleton accessible from all contexts (not actor-isolated)
  - Made `store: CNContactStore` not actor-isolated (thread-safe)
  - Read methods (contact fetching) now thread-safe, callable from any context
  - Write methods (`addRelationship`, `updateSummaryNote`, `createContact`, `refreshCache`) marked `@MainActor`
  - `configure()` and `refreshAllCaches()` marked `@MainActor` (touch modelContext)
- **Type safety improvements:**
  - All CNContactKey strings explicitly cast to `CNKeyDescriptor`
  - Added `CNContactFormatter.descriptorForRequiredKeys(for: .fullName)` to prevent property faults
  - Prevents "property was not requested when contact was fetched" crashes
- **PersonDetailView fixes:**
  - Made `imageFromContactData()` nonisolated and static for background thread access
  - Can now call from `Task.detached` without actor hopping
- **Result:** Full Swift 6 strict concurrency compliance
- **Documentation:** SWIFT6_CONCURRENCY_FIXES.md

### ContactSyncService Enhancements
- **Generic relationship method:**
  - `addRelationship(name:label:to:)` supports any CNContact relationship type
  - Replaces specific methods (addSon, addDaughter) with unified approach
  - Convenience `addChild()` method for common case (auto-detects son/daughter/child/step)
- **Error handling:**
  - `ContactSyncError` enum with localized descriptions
  - Authorization checks before every operation
  - Clear logging for debugging

### Known Issues
- **SmartSuggestionCard** designed but not yet integrated (using AnalysisArtifactCard currently)
- **SwiftData faults:** Some `@Model` objects accessed outside context (warnings, not crashes)
- **Notes entitlement:** Pending Apple approval (~1 week estimated)

## 2026-02-07 – Developer Tools & Database Fixes
- Fixed FixtureSeeder trailing comma bug that left SamInsight.kind uninitialized, causing crashes.
- Improved "Restore developer fixture" with proper dependency-order deletion (insights → notes → evidence → relationships → people/contexts).
- Added "Clean up corrupted insights" utility button for targeted repairs without full wipe.
- Automatic Calendar & Contacts sync triggered after cleanup/restore operations.
- Added LLMStatusTracker with bottom status bar indicator showing "Analyzing note..." during AI operations.

## 2026-02-07 – Permission Dialog UX Fix
- Fixed unexpected Contacts permission prompts at startup.
- Added authorization guards to ContactValidator and isInSAMGroup.
- Switched ContactPhotoFetcher to use ContactsImportCoordinator.contactStore (shared instance).
- Removed intermediate alerts in Settings; requests go directly to system dialogs.
- Centralized permission flow via PermissionsManager.
- Result: Predictable, user-initiated permission dialogs only.

## 2026-02-07 – Notes-first Evidence Pipeline
- Introduced SamNote and SamAnalysisArtifact (@Model) and added to schema (SAM_v5).
- End-to-end: SamNote → SamAnalysisArtifact → SamEvidenceItem → signals → SamInsight.
- Heuristic NoteLLMAnalyzer extracts people, topics, facts, implications, and sentiment.
- Insights include detailed, context-aware messages; appear on relevant person/context pages.
- Fixed bidirectional inverse relationships (SamPerson.insights ↔ SamInsight.samPerson).
- Developer tooling: improved restore developer fixture; comprehensive debug logging.

## 2026 – Phase 3: Evidence Relationships (Complete)
- Replaced evidenceIDs with @Relationship basedOnEvidence on SamInsight.
- Added inverse supportingInsights to SamEvidenceItem; delete rule .nullify.
- Backup/Restore: BackupInsight DTO preserves evidence links.
- Computed property interactionsCount derives from basedOnEvidence.count.

## 2026 – Concurrency & Model Container
- SAMModelContainer.shared marked nonisolated to avoid MainActor inference.
- newContext() kept nonisolated for background work.
- Seed hook moved to SeedHook.swift and kept @MainActor.

## 2026 – Phase 4: Core UX Refinement (Highlights)
- Search & filtering in People, Contexts, Inbox with persisted filter state.
- Sidebar badges for Awareness and Inbox with timed/triggered refresh.
- Detail view quick actions and keyboard shortcuts across primary views.
- Keyboard Shortcuts Palette (⌘/) and sidebar navigation shortcuts (⌘1–⌘4).

## 2026 – Backup & Restore Improvements
- AES-256-GCM + PBKDF2 encrypted backups with versioned DTOs.
- Relationship re-linking by UUID on restore.

## 2025 – Insight Generation Pipeline (Complete)
- Debounced generation triggered post-import and on app launch (safety net).
- Duplicate prevention (composite uniqueness: person + context + kind).
- Evidence aggregation to single insights; lifecycle logging.

## Earlier (Pre-2025) – Foundations
- Calendar/Contacts single shared stores with macOS per-instance auth cache behavior documented.
- Repository configuration and schema fallback to prevent early-init crashes.
