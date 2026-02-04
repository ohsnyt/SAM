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
- Incremental updates with throttling (5min normal, 10sec after calendar change)
- Pruning: removes Evidence when events are deleted or moved out of SAM calendar
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
| Views using SwiftData | `InboxListView`, `AwarenessHost` ✅ | — | — |
| Views still using mock store | `EvidenceDrillInSheet` ⏳ | `PersonDetailHost`, `InboxDetailView`, `InboxDetailSections` ⏳ | `ContextListView`, `AppShellView` (context detail host), `InboxDetailView`, `InboxDetailSections`, `PersonDetailHost` ⏳ |

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

10. **Resolve the compile error** reported in `MockContextRuntimeStore.swift:33` — `ContextListItemModel.kind` expects `SamContextKind` but `ContextDetailModel.kind` is `ContextKind`. Either:
    - Align both to `ContextKind` (the enum that already exists in `SAMModelEnums.swift` and is used by `SamContext`), or
    - Add a mapping step in the repository layer when constructing list items.
    - This will naturally resolve when Phase C replaces the mock store.
