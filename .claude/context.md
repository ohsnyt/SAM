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
- **Search bar** owned by `InboxHost`, passed to `InboxListView` as `@Binding`. `.searchable` is on the `HSplitView` (macOS) / `NavigationStack` (iOS), not on the `List` — putting it on the `List` inside a bare `HSplitView` caused a phantom padding region to appear/disappear on selection changes.

**Awareness**
- Groups signals into EvidenceBackedInsights
- Three categories: Needs Attention, Suggested Follow-Ups, Opportunities
- Shows message, confidence, evidence count
- Drill into supporting evidence
- **AwarenessHost migrated** — uses `EvidenceRepository.shared` and `SamEvidenceItem` (see migration log below)

**People & Contexts**
- Create/manage People (individuals, business owners, recruits, vendors, partners)
- Create/manage Contexts (Household, Business, Recruiting)
- Duplicate detection on creation
- ContextDetailView shows participants, products, consent, interactions, insights
- **Still backed by `MockPeopleRuntimeStore` / `MockContextRuntimeStore`** — next migration phase

**Settings (macOS style)**
- Calendar permission management
- Calendar selection/creation
- Contacts permission status (not yet used)
- Import window configuration
- Toggle calendar import on/off

**Backup & Restore (SwiftData)**
- Versioned DTOs for export/import with JSON envelope format
- AES-256-GCM + PBKDF2 encryption for secure backups
- Password stored securely in system Keychain (accessible via Passwords app)
- UI integration for export and restore flows under Settings → Backup
- `BackupPayload` already reads/writes `SamPerson`, `SamContext`, `SamEvidenceItem` directly — fully SwiftData-native

**Developer Fixtures**
- DEBUG-only seeding of SwiftData stores at app startup for rapid dev iteration
- `FixtureSeeder` seeds `SamPerson`, `SamContext`, and `SamEvidenceItem` with stable UUIDs
- `SAMStoreSeed` is the one-time migration path from mock arrays → SwiftData (guarded by `sam.swiftdata.seeded` flag)
- Developer-only restore button in Settings → Backup to reset app state to known fixture set

---

### 🏗️ Architecture

**Navigation:** `NavigationSplitView` with sidebar (Awareness, People, Contexts, Inbox). No nested `NavigationStack`s.

**Data layer (three tiers, mid-migration):**

| Tier | Evidence | People | Contexts |
|---|---|---|---|
| `@Model` class | `SamEvidenceItem` ✅ | `SamPerson` ✅ | `SamContext` ✅ |
| Repository / store | `EvidenceRepository` ✅ | `MockPeopleRuntimeStore` ⏳ | `MockContextRuntimeStore` ⏳ |
| Views using SwiftData | `InboxListView`, `InboxDetailView`, `AwarenessHost` ✅ | — | — |
| Views still using mock store | `EvidenceDrillInSheet` ⏳ | `PersonDetailHost`, `InboxDetailSections` ⏳ | `ContextListView`, `AppShellView` (context detail host), `InboxDetailSections`, `PersonDetailHost` ⏳ |

---

## Migration Notes (SwiftData)

- **Naming strategy:** SwiftData `@Model` types use `Sam…` prefixes (e.g., `SamEvidenceItem`, `SamPerson`, `SamContext`). Enums and embedded value types live in `SAMModelEnums.swift` (e.g., `ContextKind`, `EvidenceSignal`, `SignalKind`, `InsightKind`). UI-only helpers are scoped or renamed to avoid collisions.
- **Codable boundaries:** `@Model` types are **not** `Codable`. Only Backup DTOs (`BackupPerson`, `BackupContext`, `BackupEvidenceItem`) and embedded value types are `Codable` for export/import.
- **Backup path:** `BackupPayload.current(using: ModelContainer)` snapshots SwiftData; `payload.restore(into: ModelContainer)` replaces live data. Encryption uses AES-256-GCM with PBKDF2-derived key.
- **Seeder:** `FixtureSeeder.seedIfNeeded(using:)` runs in DEBUG only at app startup and is idempotent (stable UUIDs for deterministic relationships).
- **One-time migration:** `SAMStoreSeed.seedIfNeeded(into:)` migrates the original mock arrays into SwiftData once per install. Three-pass ordering: Contexts → People → Evidence (Evidence's `proposedLinks` resolve `targetID`s against freshly-inserted People/Contexts).
- **Previews:** Use in-memory `ModelContainer` with minimal seeding; avoid mock-era stores in previews.
- **Developer tooling:** Settings → Backup includes a DEBUG-only "Restore developer fixture" that wipes and reseeds.
- **Schema hygiene:** The app's `ModelContainer` must list every `@Model` type. Keep the schema list and model declarations in sync.

---

## Migration Log

### 2026-02-04 — Calendar import end-to-end + Inbox detail migration

**`EvidenceRepository` was writing to an orphan `ModelContainer`**
- `EvidenceRepository.shared` is a singleton created at class-load time via `static let shared = EvidenceRepository()`.  Its `init` defaulted to `try! ModelContainer(for: SamEvidenceItem.self)` — a brand-new, private container.  `CalendarImportCoordinator` wrote calendar evidence into that container; `InboxListView`'s `@Query` read from `SAMModelContainer.shared` (injected via `.modelContainer()` on the view hierarchy).  Two separate stores; writes were invisible.  Fix: added `configure(container:)` on `EvidenceRepository`; `SAM_crmApp.task` calls it with `SAMModelContainer.shared` before the first calendar kick.  `container` changed from `let` to `var`.

**Inbox detail pane stayed blank on selection**
- `InboxDetailView.body` looked up the selected item with `if let item = try? repo.item(id: evidenceID)`.  `repo.item(id:)` is a one-shot `FetchDescriptor` query — SwiftData has no way to tell SwiftUI the result changed.  On macOS SwiftUI was free to skip re-evaluating the child when only the selection binding changed, so the detail pane frequently rendered `EmptyDetailView`.  Fix: introduced `InboxDetailLoader`, a dedicated struct whose `@Query` (unfiltered, sorted) keeps SwiftUI in the loop.  The selected item is derived via `allItems.first { $0.id == id }`.  A dynamic `#Predicate` inside a custom `init` was deliberately avoided: that combination triggers a Swift 6.2 compiler crash (`recordOpenedTypes` assertion in the constraint solver / `TypeOfReference.cpp:656`).

**Phantom padding above the Inbox list on selection**
- `.searchable` was on the `List` inside the `HSplitView`.  On macOS, `.searchable` injects a search bar into the nearest toolbar region; when the owning view is a bare `List` inside an `HSplitView` (not a `NavigationStack`) macOS reserves space for the search bar and that space flickers on selection change.  Fix: `searchText` ownership moved to `InboxHost` as `@State`; `.searchable` applied to the `HSplitView` itself (macOS) or the `NavigationStack` (iOS).  `InboxListView` receives `searchText` as a `@Binding`.

**`EKEventStore` per-instance auth cache — calendar events never appeared**
- On macOS `EKEventStore.authorizationStatus(for: .event)` is backed by a per-instance cache.  The instance that calls `requestFullAccessToEvents()` is the only one whose cache updates after the user grants permission.  `CalendarImportCoordinator` had `private let eventStore = EKEventStore()` and `SamSettingsView` had `private static let eventStore = EKEventStore()` — two separate instances.  Settings requested permission on its instance; the coordinator checked auth on its own instance and saw `.notDetermined` forever.  Fix: `eventStore` is now `static let` on `CalendarImportCoordinator` and is the single shared instance for the entire app.  All `Self.eventStore` references in `SamSettingsView` were replaced with `CalendarImportCoordinator.eventStore`.  The coordinator also calls `requestFullAccessToEvents()` at the top of every import run (idempotent when already granted) to guarantee its cache is warm.

**Permission grant and calendar selection never kicked the import**
- The only things that kicked `CalendarImportCoordinator` were: app launch, app-became-active, and `EKEventStoreChanged`.  On macOS granting Calendar permission does not reliably fire `EKEventStoreChanged`, and the app is already foreground so `didBecomeActive` doesn't re-fire.  Selecting a calendar in the Settings picker just wrote to `@AppStorage` — nobody listened.  Fix: `requestCalendarAccessAndReload()` now kicks with reason `"calendar permission granted"` after the auth status refreshes to `.fullAccess`.  The calendar Picker gained an `onChange(of: selectedCalendarID)` that kicks with `"calendar selection changed"`.

**"Permission granted" kick was throttled at 5 minutes**
- `importIfNeeded` used `reason.contains("changed")` to decide between the 10-second and 5-minute throttle intervals.  The new `"calendar permission granted"` kick didn't match.  Fix: inverted the logic.  Periodic triggers (`"app launch"` / `"app became active"`) get the conservative 5-minute interval; everything else (any event-driven reason) gets the fast 10-second interval.

**Layout-recursion warning from `PopoverAnchorView`**
- `PopoverAnchorView` (an `NSViewRepresentable` used to capture an anchor `NSView` for AppKit popover presentation) set its `@Binding` inside `makeNSView` via `DispatchQueue.main.async`.  That async dispatch could land during a layout pass, triggering: *"It's not legal to call -layoutSubtreeIfNeeded on a view which is already being laid out."*  Fix: removed the async dispatch from `makeNSView`; the binding is now set in `updateNSView` with an identity guard (`if anchorView !== nsView`).  `updateNSView` is guaranteed to run after layout settles.

---

### 2026-02-04 — Settings & Backup UX fixes

**Settings window blocked after permission-nudge dismissal**
- `PermissionNudgeSheet` called `openSettings()` then `dismiss()` synchronously.  On macOS the sheet is a modal window; dismissing it while it is still key raced with the Settings scene appearing and caused the Settings window to land behind the main window or never become key.  Fix: `dismiss()` first, then `openSettings()` on the next run-loop tick via `DispatchQueue.main.async`.

**Settings TabView selection was frozen (tabs non-interactive)**
- `SamSettingsView`'s `TabView` was bound to a hand-rolled `Binding` that read/wrote a `static var` backed by raw `UserDefaults`.  SwiftUI has no way to observe raw `UserDefaults` writes, so the tab selection was set once at initial render and never updated — tapping tabs wrote the new value but nothing told SwiftUI to re-read it.  Fix: added an `@AppStorage("sam.settings.selectedTab")` property (`_selectedTab`) on the view and bound the `TabView` to it directly (`$_selectedTab`).  The `static var` is kept for external write-before-open (nudge sheet, `openToPermissions()`); `@AppStorage` reads the same key and publishes changes.

**Permission-grant status update was intermittent (~50 %)**
- `PermissionsTab`, `ImportTab`, and `ContactsTab` all received `calendarAuthStatus` / `contactsAuthStatus` as plain `let` values.  When `refreshAuthStatuses()` wrote the new status into `SamSettingsView`'s `@State`, SwiftUI was free to skip re-rendering stable child identities inside a `TabView` — so the children sometimes never saw the update.  Fix: changed all three statuses to `@Binding` end-to-end (declaration in each child struct + `$` at every call site).

**Restore flow asked for password before file (UX order)**
- `RestoreBackupSheet` presented a password field first and gated the file picker behind it.  This forced the user to remember and type a password before knowing which file — or even whether the file was readable.  Fix: split the single `chooseAndDecrypt()` into two distinct steps.  Step 1 shows only "Choose File…"; once a file is picked its raw bytes are held in `pendingData` and the sheet transitions to Step 2, which shows the filename in context and asks for the password.  A "Back" button lets the user re-pick.  Decrypt + decode only runs after both inputs are present.

**UTType `.sam-backup` registration documented (action item)**
- The `UTType("com.sam-crm.sam-backup")` constant was already in place, and both `NSSavePanel` / `NSOpenPanel` referenced it.  However, the exported-type declaration was not confirmed in the target's Info.plist.  Without it the OS does not know that `.sam-backup` maps to the identifier, so the open-panel filter may not reliably restrict to backup files.  The comment on the `UTType` extension now contains the exact Xcode UI steps and the raw XML block needed.  **Action required:** register the exported type in the app target before shipping.

---

### 2026-02-04 — Compile-error sweep & seeder fix

**`#Predicate` enum-case key paths fixed everywhere**
- `InboxListView`, `EvidenceRepository` (`needsReview()`, `done()`, `pruneCalendarEvidenceNotIn`): all `#Predicate` closures that compared a `String`-backed enum property directly against an enum case now compare `.rawValue` on both sides.  The `#Predicate` macro cannot expand enum-case key paths for `RawRepresentable` types; comparing raw `String` values is the correct workaround.

**Phantom `Sam`-prefixed type names removed**
- `InsightGeneratorV1`: `SamEvidenceSignal` → `EvidenceSignal`, `SamEvidenceSignalKind` → `SignalKind` (7 constructor calls + 2 type annotations).
- `InboxDetailView`: `SamLinkSuggestionStatus` → `LinkSuggestionStatus`, `SamParticipantHint` → `ParticipantHint`, `SamEvidenceLinkTarget` → `EvidenceLinkTarget`.
- `SAMModelContainer` schema list: `EvidenceItem` → `SamEvidenceItem`.

**Duplicate `SamContextKind` enum removed**
- `ContextListModels.swift`: deleted the `SamContextKind` enum (identical to `ContextKind` in `SAMModelEnums.swift`); `ContextListItemModel.kind` now uses `ContextKind` directly.  No call-site changes needed — `ContextDetailModel.kind` was already `ContextKind`.

**`SAMStoreSeed` Pass 3 (evidence) rewritten**
- Removed the stale `MockEvidenceRuntimeStore.shared` / `.items` reference.  Evidence is now seeded by `FixtureSeeder` before `SAMStoreSeed` runs; Pass 3 fetches the already-present `SamEvidenceItem` objects from the `ModelContext` and re-maps their `proposedLinks` / `linkedPeople` / `linkedContexts` UUIDs in place.

---

### 2026-02-04 — Evidence layer fully migrated

**`MockEvidenceRuntimeStore.swift` rewritten → `EvidenceRepository`**
- The file still has its old filename (`MockEvidenceRuntimeStore.swift`) but the class inside is now `EvidenceRepository`.
- It accepts a `ModelContainer`, runs `FetchDescriptor` queries against `SamEvidenceItem`, and persists through `ModelContext`.
- All CRUD: `needsReview()`, `done()`, `item(id:)`, `upsert(_:)`, `pruneCalendarEvidenceNotIn(…)`, `markDone`, `reopen`, link/unlink, suggestion accept/decline, `replaceAll(with:)` for backup restore.
- **Rename pending:** `MockEvidenceRuntimeStore.swift` → `EvidenceRepository.swift`

**`AwarenessHost.swift` migrated to `EvidenceRepository`**
- `MockEvidenceRuntimeStore.shared` → `EvidenceRepository.shared`
- `evidenceStore.needsReview` (old property) → `(try? evidenceStore.needsReview()) ?? []` (now a throwing `FetchDescriptor` query)
- All `EvidenceItem` type references → `SamEvidenceItem`
- `bestTargetName(from:)` still uses `MockPeopleRuntimeStore` / `MockContextRuntimeStore` for UUID → name resolution; will update when People/Contexts migrate

---

## 📋 Planned Tasks (next phases)

### Phase A — Finish Evidence surface migration (quick wins)

1. **Rename file:** `MockEvidenceRuntimeStore.swift` → `EvidenceRepository.swift` (cosmetic, no code change)
2. **`EvidenceDrillInSheet.swift`** — still references `MockEvidenceRuntimeStore.shared` and the old `EvidenceItem` type / `.items` property. Swap to `EvidenceRepository` the same way `AwarenessHost` was updated. Note: the sheet fetches by a set of IDs, so it will need a helper or loop over `evidenceStore.item(id:)` rather than filtering a flat array.

### Phase B — People repository (mirrors Evidence pattern)

3. **Create `PeopleRepository`** in a new file (or rewrite `MockPeopleRuntimeStore.swift` in place). Pattern to follow: `EvidenceRepository`. Key operations needed by current call-sites:
   - `byID: [UUID: SamPerson]` (or async `person(id:)`)
   - `listItems` (derived from `SamPerson` fetch)
   - `add(_:)` / `resolveContactIdentifier(personID:)` / `patchContactIdentifier(…)`
   - `addContext(personID:context:)` — updates the denormalised `contextChips` array on `SamPerson`
4. **Migrate call-sites:**
   - `PersonDetailHost.swift` — `peopleStore` and `contextStore` refs
   - `InboxDetailView.swift` — `peopleStore`, `contextStore`, and the nested `ensurePersonExists` helper
   - `InboxDetailSections.swift` — passed-down `peopleStore` / `contextStore` props
   - `AwarenessHost.swift` → `bestTargetName` — the two remaining mock store refs

### Phase C — Contexts repository (mirrors Evidence pattern)

5. **Create `ContextRepository`** (or rewrite `MockContextRuntimeStore.swift`). Key operations:
   - `byID: [UUID: SamContext]`
   - `listItems` (derived)
   - `add(_:)` / `addParticipant(…)`
   - Fix the `ContextKind` vs `SamContextKind` type mismatch surfaced in `listItems` — confirm which enum the `ContextListItemModel.kind` field expects and align
6. **Migrate call-sites:**
   - `ContextListView.swift` — `store` ref
   - `AppShellView.swift` — context-detail host `store` ref
   - All sites already listed in Phase B that also touch `contextStore`

### Phase D — Clean up legacy scaffolding

7. **Remove `MockPeopleStore` / `MockContextStore` static seed arrays** from `AppShellView.swift` (and wherever else they live) once Phases B & C are complete — `FixtureSeeder` and `SAMStoreSeed` are the sole source of seed data now.
8. **Remove `SAMStoreSeed`** once confidence is high that all installs have migrated (the `sam.swiftdata.seeded` flag can be checked for a release or two before deleting).
9. **Audit `ContextDetailModel` / `PersonDetailModel` structs** — these are the view-layer value types that the mock stores returned. Decide: keep as lightweight view-models populated from `@Model` objects, or replace detail views with direct `@Model` bindings.

### Phase E — `ContextKind` vs `SamContextKind` error

10. **~~Resolve the compile error~~** ✅ **Done 2026-02-04.** Removed the duplicate `SamContextKind` enum from `ContextListModels.swift`; `ContextListItemModel.kind` now uses the canonical `ContextKind` from `SAMModelEnums.swift`. No call-site changes were required — `ContextDetailModel.kind` was already `ContextKind`, so `MockContextStore.listItems` compiles without modification.
