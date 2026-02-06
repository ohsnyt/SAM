# SAM - Project Context

## What SAM Is

A native macOS SwiftUI application for independent financial strategists (insurance agents). It observes interactions (Calendar events, later Contacts/Mail/Zoom), creates Evidence, and generates Evidence-backed Insights that suggest relationship management actions.

**Core principle:** AI assists but never acts autonomously. User reviews and approves everything.

---

## Current Project Status

### ✅ Working Features

**Calendar Integration**
- User selects/creates a "SAM" calendar
- Imports events (configurable past/future window)
- Incremental updates with throttling (5min for periodic triggers like app launch / app became active; 10sec for event-driven triggers: calendar changed, permission granted, selection changed)
- Pruning: removes Evidence when events are deleted or moved out of SAM calendar
- **Single shared `EKEventStore`** lives on `CalendarImportCoordinator.eventStore` (static). All EventKit calls in Settings and the coordinator use this instance. On macOS the per-instance auth cache means the instance that calls `requestFullAccessToEvents()` must be the same one that later queries calendars — a second instance will see a stale `.notDetermined` status forever.
- **Fixed bug:** Eliminated duplicate evidence (now single import path via CalendarImportCoordinator)

**Contacts Integration (Group-based)**
- User selects an existing Contacts group or creates a new "SAM" group in Settings → Permissions (Contacts).
- Imports all members of the selected group into SwiftData as `SamPerson` via `PeopleRepository`.
- Upsert key: `CNContact.identifier` (stored on `SamPerson.contactIdentifier`). Existing people are updated with the latest display name and first email; no duplicates are created.
- Throttling mirrors calendar import semantics:
  - 5 minutes for periodic triggers (e.g. "app launch")
  - 10 seconds for event-driven triggers (Contacts database changed, group selection changed)
- "Sync Now" is available in both the Permissions and Contacts tabs.
- Single shared `CNContactStore` lives on `ContactsImportCoordinator.contactStore` to avoid change-anchor/cache issues.
- App wiring:
  - Kicks on app launch
  - Subscribes to `.CNContactStoreDidChange` and kicks on change
- Non-destructive: contacts removed from the group are not deleted from SAM yet (see Planned Tasks for pruning strategy).
- PeopleRepository now supports batched writes (beginImportSession/endImportSession) and a bulkUpsert helper so ContactsImportCoordinator commits a single save per import; SwiftData views update consistently on save.

**Evidence & Signals**
- Calendar events → EvidenceItems with deterministic signals
- Signal types: unlinkedEvidence, divorce, comingOfAge, partnerLeft, productOpportunity, complianceRisk
- InsightGeneratorV1 applies keyword-based rules to generate signals

**Inbox**
- Shows EvidenceItems needing review (state: needsReview)
- Link evidence to People/Contexts
- Accept/decline proposed links
- Mark done, reverse decisions
- EvidenceDrillInSheet for details
- **InboxListView is fully migrated to SwiftData** — uses `@Query` directly against `SamEvidenceItem`
- **InboxDetailView migrated** — `InboxDetailLoader` uses an unfiltered `@Query` + in-Swift `.first { $0.id == id }` filter. A dynamic `#Predicate` inside a custom `init` was avoided because it triggers a Swift 6.2 compiler crash (`recordOpenedTypes` assertion in the constraint solver). The unfiltered query is fine: the Inbox table is small, and `@Query` invalidation fires on any `SamEvidenceItem` mutation so the detail pane stays live.
- **InboxDetailSections is fully SwiftData-native** — all sections (Header, Evidence, Participants, Signals, SuggestedLinks, ConfirmedLinks, Actions) operate directly on `SamEvidenceItem`.
- **Participant resolution on macOS** — after a new contact is created in Contacts.app, `InboxDetailView` runs a background `CNContactStore` lookup after a 2-second delay, patches `ParticipantHint.isVerified`, and calls `ensurePersonExists` to either create a `SamPerson` or patch its `contactIdentifier`. All CNContact I/O is done off the main actor via `Task.detached`; only the final mutation runs on `MainActor`.
- **Search bar** owned by `InboxHost`, passed to `InboxListView` as `@Binding`. `.searchable` is on the `HSplitView` (macOS) / `NavigationStack` (iOS), not on the `List` — putting it on the `List` inside a bare `HSplitView` caused a phantom padding region to appear/disappear on selection changes.

**Awareness**
- Groups signals into EvidenceBackedInsights
- Three categories: Needs Attention, Suggested Follow-Ups, Opportunities
- Shows message, confidence, evidence count
- Drill into supporting evidence
- **AwarenessHost migrated** — uses `EvidenceRepository.shared` and `SamEvidenceItem`. Name cache invalidates on app-active, `EKEventStoreChanged`, and `CNContactStoreDidChange`.

**People & Contexts**
- Create/manage People (individuals, business owners, recruits, vendors, partners)
- Create/manage Contexts (Household, Business, Recruiting)
- Duplicate detection on creation
- ContextDetailView shows participants, products, consent, interactions, insights
- **PeopleListView fully migrated to SwiftData** — uses `@Query` on `SamPerson`; maps to `PersonListItemModel` so `PersonRow` remains unchanged. Search, selection, auto-select, and the "+" toolbar button all work end-to-end.
- **Unlinked-badge flow in PersonRow** — when `contactIdentifier` is nil, an orange `person.crop.circle.badge.questionmark` icon appears as a tappable button. Tapping it opens `LinkContactSheet`, which: (1) confirms intent, (2) runs `PersonDuplicateMatcher` (Jaccard + surname boost + nickname normalisation, 0.60 threshold) against all existing `SamPerson` rows, (3) if duplicates are found presents a 3-way choice — Merge into the duplicate (adopts its `contactIdentifier`), Search Contacts app, or Create New Contact; if no duplicates are found the choice is Search or Create.
- **PersonDetailHost fully migrated to SwiftData** — uses a filtered `@Query` on `SamPerson` keyed to `selectedPersonID`. Maps `SamPerson` → `PersonDetailModel` for the existing `PersonDetailView`. Derives context chips from `participations` relationships (with a fallback to the denormalized `contextChips` array). "Add to Context" sheet creates a live `ContextParticipation` row and updates both the relational graph and the denormalized chip array in a single save.
- **Person detail header image rules** — (a) unlinked (`contactIdentifier == nil`): the image area is left completely blank; `ContactPhotoFetcher` is not called. (b) linked but no photo available: a subtle `person.circle` SF Symbol is rendered at 33% secondary opacity as an unobtrusive placeholder. (c) linked with photo: the thumbnail is shown at 65% opacity with a bottom-left gradient fade so it dissolves gently into the card rather than sitting as a hard shape.
- **Person merge (LinkContactSheet flow)** — `mergePerson` re-points participations, coverages, consent requirements, and responsibilities (both guardian and dependent directions) from the source to the survivor, adopts the source's `contactIdentifier` if the survivor lacks one, and deletes the source row. Selection pivots to the survivor automatically.
- **LinkContactSheet** — macOS-only modal sheet that walks the user through linking an unlinked `SamPerson` to an existing linked contact. Flow: (1) confirms intent, (2) runs `PersonDuplicateMatcher` (Jaccard + surname boost + nickname normalisation, 0.60 threshold), (3) shows a **searchable picker** with suggested matches at the top (with confidence badges) followed by all linked contacts sorted by last name. User can search by name/address/phone, tap any contact to **merge** the unlinked person into that contact, or click "Create New Contact" to open a vCard in Contacts.app for truly new contacts. Tapping any picker row triggers a full merge (via `onMerge`) — the selected contact becomes the survivor, all relationships are re-pointed, and the unlinked source is deleted. This eliminates duplicate `SamPerson` records pointing to the same `contactIdentifier`.
- **ContextListView fully migrated to SwiftData** — uses `@Query` on `SamContext`; maps to `ContextListItemModel`. Filter pills (All / Households / Business / Recruiting), search, selection, and auto-select all work end-to-end.
- **ContextDetailRouter** — reads `SamContext` from SwiftData via `@Query`, maps it to `ContextDetailModel` (including participants from the `participations` relationship, embedded product cards, consent requirements, interactions, and insights), and hands it to the existing `ContextDetailView`. This is the live SwiftData path for the detail pane.

**Settings (macOS style)**
- Calendar permission management
- Calendar selection/creation
- Contacts permission status
- Import window configuration
- Toggle calendar import on/off
- Contacts group selection + "Sync Now"

**Backup & Restore (SwiftData)**
- Versioned DTOs for export/import with JSON envelope format
- AES-256-GCM + PBKDF2 encryption for secure backups
  - Wire format: `[16B salt][12B nonce][ciphertext][16B GCM tag]`
  - Key derivation: PBKDF2-SHA256, 100 000 iterations, 256-bit output
  - `kCCPRFHmacAlgoSHA256` is not bridged on macOS; a named constant + compile-time `precondition` guard is in place so a future value change produces a loud build failure rather than a silent key-derivation mismatch
- Password stored securely in system Keychain (accessible via Passwords app)
- UI integration for export and restore flows under Settings → Backup
- `BackupPayload` already reads/writes `SamPerson`, `SamContext`, `SamEvidenceItem` directly — fully SwiftData-native
- Restore path re-links evidence → people/context relationships by UUID after all three model types are inserted
- Delete order on restore is Evidence → Contexts → People (reverse of insert order) to avoid cascade issues on relationship-bearing models
- `bulkUpsertFromContacts` collects per-item errors and logs them but still commits successful upserts; the final `endImportSession` save propagates if it fails

**Contact Validation & Sync**
- `ContactValidator` (stateless utility) checks contact existence and optional SAM group membership (macOS only)
- `ContactsSyncManager` (@Observable) monitors `CNContactStoreDidChange` notifications and validates all linked `SamPerson.contactIdentifier` values
- Automatic validation on app launch (configurable) and when Contacts.app changes
- All CNContactStore I/O on background threads via `Task.detached`
- Clears stale `contactIdentifier` values when contacts are deleted or removed from SAM group
- `ContactSyncStatusView` displays banner notification when links are auto-cleared
- `ContactSyncConfiguration` provides app-wide settings (SAM group filtering, launch validation toggle, banner auto-dismiss delay, debug logging)
- Integrated in `PeopleListView` (shows banner, observes sync manager) and `PersonDetailView` (validates before photo fetch)
- Platform differences: macOS supports SAM group filtering; iOS validates existence only (groups are read-only)

**Developer Fixtures**
- DEBUG-only seeding of SwiftData stores at app startup for rapid dev iteration
- `FixtureSeeder` seeds `SamPerson`, `SamContext`, and `SamEvidenceItem` with stable UUIDs (`SeedIDs`)
- `SAMStoreSeed` runs once (guarded by `sam.swiftdata.seeded`); its only live job is resolving `proposedLink.targetID`s. On fresh installs it is effectively a no-op because `FixtureSeeder` already uses the correct UUIDs.
- Developer-only restore button in Settings → Backup to reset app state to known fixture set

---

### 🏗️ Architecture

**Navigation:** `NavigationSplitView` with sidebar (Awareness, People, Contexts, Inbox). No nested `NavigationStack`s. Sidebar selection persisted via `@AppStorage`. Awareness and Inbox use a 2-column layout (sidebar + detail); People and Contexts use a 3-column layout (sidebar + content list + detail).

**Data layer (three tiers):**

| Tier | Evidence | People | Contexts |
|---|---|---|---|
| `@Model` class | `SamEvidenceItem` | `SamPerson` | `SamContext` |
| Repository / store | `EvidenceRepository` | `PeopleRepository` | — |
| Views using SwiftData | `InboxListView`, `InboxDetailView`, `InboxDetailSections`, `AwarenessHost` | `PeopleListView`, `PersonDetailHost` | `ContextListView`, `ContextDetailRouter` |

**Key singletons and shared state:**
- `EvidenceRepository.shared` — configured once at app launch with the app-wide `ModelContainer`. All calendar-import writes and Inbox reads go through this instance.
- `CalendarImportCoordinator.eventStore` (static) — the single `EKEventStore` for the entire app. Settings and the coordinator both reference this instance.
- `ContactsImportCoordinator.contactStore` — the single `CNContactStore` for group-based import.

---

## Migration Notes (SwiftData)

- **Naming strategy:** SwiftData `@Model` types use `Sam…` prefixes (e.g., `SamEvidenceItem`, `SamPerson`, `SamContext`). Enums and embedded value types live in `SAMModelEnums.swift` (e.g., `ContextKind`, `EvidenceSignal`, `SignalKind`, `InsightKind`). UI-only helpers are scoped or renamed to avoid collisions.
- **Codable boundaries:** `@Model` types are **not** `Codable`. Only Backup DTOs (`BackupPerson`, `BackupContext`, `BackupEvidenceItem`) and embedded value types are `Codable` for export/import.
- **Backup path:** `BackupPayload.current(using: ModelContainer)` snapshots SwiftData; `payload.restore(into: ModelContainer)` replaces live data. Encryption uses AES-256-GCM with PBKDF2-derived key.
- **Seeder:** `FixtureSeeder.seedIfNeeded(using:)` runs in DEBUG only at app startup and is idempotent (stable UUIDs for deterministic relationships).
- PeopleRepository: batching support for imports (beginImportSession/endImportSession) and bulkUpsert to minimize save churn and improve UI refresh timing.
- **One-time bootstrap:** `SAMStoreSeed.seedIfNeeded(into:)` runs once per install (guarded by `sam.swiftdata.seeded`). On fresh installs `FixtureSeeder` pre-populates the store with stable UUIDs; `SAMStoreSeed` only re-maps `proposedLink.targetID`s as a safety net. Do not add new seed logic here — put it in `FixtureSeeder`.
- **Previews:** Use in-memory `ModelContainer` with minimal seeding; avoid mock-era stores in previews.
- **Developer tooling:** Settings → Backup includes a DEBUG-only "Restore developer fixture" that wipes and reseeds.
- **Schema hygiene:** The app's `ModelContainer` must list every `@Model` type. Keep the schema list and model declarations in sync.

---

## Resolved Gotchas (keep these; they will bite you if re-introduced)

These are decisions baked into the current code. The *why* matters more than the history.

- **Single shared stores only.** `EKEventStore`, `CNContactStore`, `EvidenceRepository`, and `PeopleRepository` are each singletons configured once at launch. On macOS, `EKEventStore` auth status is per-instance; a second instance will see `.notDetermined` forever. Same class of problem applies to `CNContactStore` change anchors. Never create a second instance of any of these.
- **`EvidenceRepository.configure(container:)` must be called before the first calendar import.** The default `init` creates its own private `ModelContainer`. If you skip `configure`, writes are invisible to every `@Query` in the view hierarchy.
- **`InboxDetailLoader` uses an unfiltered `@Query` + `.first { $0.id == id }`.** Do *not* replace this with a dynamic `#Predicate` in a custom `init` — that combination triggers a Swift 6.2 compiler crash (`recordOpenedTypes` / `TypeOfReference.cpp:656`). The Inbox table is small; the unfiltered fetch is fine.
- **`.searchable` must not be placed on a bare `List` inside an `HSplitView`.** On macOS it injects a search-bar toolbar region that flickers on selection change. Attach it to the `HSplitView` (macOS) or `NavigationStack` (iOS) instead.
- **`#Predicate` cannot expand enum-case key paths for `RawRepresentable` types.** All enum comparisons in predicates use `.rawValue` on both sides.
- **Throttle logic is inverted by design.** Periodic triggers (`"app launch"` / `"app became active"`) get the 5-min interval; *everything else* gets 10 sec. Don't flip this back to `reason.contains("changed")` — permission-grant kicks would silently throttle.
- **`PopoverAnchorView` sets its binding in `updateNSView`, not `makeNSView`.** An async dispatch in `makeNSView` can land during a layout pass and trigger a recursion warning. The identity guard `if anchorView !== nsView` prevents redundant updates.
- **Settings auth-status props must be `@Binding`, not `let`.** SwiftUI can skip re-rendering stable child identities inside a `TabView`; plain `let` values never update after initial render.
- **Settings `TabView` selection is bound to `@AppStorage("sam.settings.selectedTab")`.** A raw `UserDefaults` backing store is unobservable; `@AppStorage` is required.
- **`PermissionNudgeSheet` dismisses first, then opens Settings on the next run-loop tick.** Reversing the order races with the modal sheet dismissal and the Settings window lands behind.
- **Restore sheet is two-step: file picker first, password second.** Don't collapse these back into one step.
- **`BackupPayload.restore` deletes in reverse-dependency order: Evidence → Contexts → People.** Deleting a parent (People) before its dependents (Contexts, via `ContextParticipation`) can trigger unexpected cascades.
- **PBKDF2 PRF constant is guarded.** `kCCPRFHmacAlgoSHA256` is not bridged on macOS; a named constant + `precondition` at load time catches any future value change loudly.
- **`bulkUpsertFromContacts` is best-effort with visible failures.** Per-item errors are logged and returned; the session still commits for successful items. Only `endImportSession` failure aborts everything.
- **`SAMStoreSeed` Passes 1 & 2 are snapshot-only; Pass 3 is a no-op on fresh installs.** `FixtureSeeder` pre-populates People and Evidence with stable `SeedIDs`; `SAMStoreSeed` only re-maps `proposedLink.targetID`s as a safety net. Don't add new seed logic here — put it in `FixtureSeeder`. Dead helper functions (`inferProductType`, `extractPersonName`) have been removed.
- **Previews use the real embedded value types directly.** `PersonInsight` and `ContextInsight` already conform to `InsightDisplayable`. Do not create parallel mock insight structs (`ContentViewMockInsight`, `InsightCardMock`, `ContextMockInsight`, etc.) — they are redundant and drift silently.
- **`ContextDetailModel.insights` is `[ContextInsight]`.** The router in `AppShellView` passes `SamContext.insights` straight through — no `.map` conversion needed. Don't reintroduce a mock insight type here.
- **`MockEvidenceRuntimeStore.swift` still exists on disk but contains `EvidenceRepository`.** The filename is stale; the class is live.
- **File panels use `runModal()` not `beginSheetModal(for:)`.** The async sheet API requires sandbox entitlements (`User Selected File: Read/Write`). The legacy synchronous `runModal()` works without additional entitlements and is acceptable for developer/single-user tools.
- **`UTType.samBackup` is registered in Info.plist.** Exported Type Identifiers entry added (identifier `com.sam-crm.sam-backup`, conforms to `public.data`, extension `sam-backup`). File panels now properly filter `.sam-backup` files.
- **`ContactValidator` must not check `CNContactStore.authorizationStatus(for:)` before attempting lookups.** On macOS, even when access is granted, this check can fail or return stale values. The correct approach: attempt the `CNContactStore` operation directly and catch errors. Let the framework handle authorization state internally. See `BUG_FIX_SUMMARY.md` for the full story.

---

## Recently Completed

### ✅ Contact Validation & Sync System (February 2026)
**Problem:** When contacts were deleted from Contacts.app or removed from the SAM group, their `contactIdentifier` values remained in SAM indefinitely, creating stale links and failed photo fetches.

**Solution implemented:**
- `ContactValidator` — Low-level validation utilities (contact existence + optional SAM group membership checking on macOS)
- `ContactsSyncManager` (@Observable) monitors `CNContactStoreDidChange` notifications and automatically validates all linked contacts
- `ContactSyncStatusView` — UI banner notification when links are auto-cleared
- `ContactSyncConfiguration` — App-wide settings (SAM group filtering, launch validation, banner timing, debug logging)
- `ContactValidationModifiers` — SwiftUI convenience helpers for views

**Integration points:**
- `PeopleListView` instantiates and observes `ContactsSyncManager`, displays banner when `lastClearedCount` updates
- `PersonDetailView` validates contact on navigation (via `.task(id: person.id)`), skips photo fetch if invalid
- All CNContactStore I/O happens on background threads; SwiftData updates on main actor

**Testing surface:** Delete a linked contact in Contacts.app → SAM shows banner and "Unlinked" badge automatically

**Known issue resolved:** Initial implementation incorrectly called `CNContactStore.authorizationStatus(for: .contacts)` *before* attempting lookups, which caused all contacts to be marked invalid on macOS. Fixed by removing premature auth guards and letting CNContactStore throw errors naturally. See `BUG_FIX_SUMMARY.md`.

**Status:** ✅ Complete, documented (`CONTACT_VALIDATION_README.md`, `COMPLETE.md`, examples in `ContactValidationExamples.swift`)

### ✅ Validation Testing & Refinement (February 2026)
- Completed end-to-end testing of contact validation across scenarios: deletion in Contacts.app, removal from SAM group (macOS), and normal retention.
- Enabled and verified SAM group filtering where applicable (macOS); confirmed iOS path validates existence only.
- Verified banner notifications, performance on larger contact sets, and background revalidation on `CNContactStoreDidChange`.
- Temporarily enabled debug logging to trace validation; disabled after confirmation.
- Outcome: Validation is stable and behaving as designed; no further action required.

---

## Planned Tasks (prioritised)

1. **Promote Insights to a first-class `@Model`** — Insights are currently denormalized `PersonInsight` / `ContextInsight` value types embedded on `SamPerson` and `SamContext`. Promoting them enables persistence across launches, dismissal memory, and the explainability links (back to evidence) that the Awareness drill-through needs. **Scope question to resolve first:** `AwarenessHost` derives its own `EvidenceBackedInsight` structs independently from `SamEvidenceItem.signals` — it does not use `PersonInsight` or `ContextInsight` at all. The design doc (`data-model.md §13`) calls for a single unified `Insight @Model` that both Person/Context detail and Awareness share. Confirm that intent before starting; the migration surface is larger than it first appears.

2. **Awareness → Person/Context drill-through** — Tapping an insight card in Awareness should navigate to the relevant person or context. **Blocked on #1:** `EvidenceBackedInsight` currently carries only `evidenceIDs`; it has no person or context reference, so there is nothing to navigate to until Insight becomes a persisted model with explicit `samContact`/`context` relationships. The sidebar-selection bindings (`selectedPersonID`, `selectedContextID`) are also scoped to `AppShellView` and will need to be surfaced via an `EnvironmentKey` or passed closure once the target is known.

3. **Contact validation enhancements (optional)** — Once basic validation is proven stable, consider: (a) inline warnings in `PersonDetailView` when contact is invalid, (b) smart re-linking suggestions when a contact with the same email is created, (c) undo support for auto-unlinking, (d) audit log tracking when/why links were cleared, (e) conflict resolution UI (offer to re-add to SAM group instead of unlinking). See `CONTACT_VALIDATION_README.md` "Future Enhancements" section.





