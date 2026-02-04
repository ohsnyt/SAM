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

**Awareness**
- Groups signals into EvidenceBackedInsights
- Three categories: Needs Attention, Suggested Follow-Ups, Opportunities
- Shows message, confidence, evidence count
- Drill into supporting evidence

**People & Contexts**
- Create/manage People (individuals, business owners, recruits, vendors, partners)
- Create/manage Contexts (Household, Business, Recruiting)
- Duplicate detection on creation
- ContextDetailView shows participants, products, consent, interactions, insights

**Settings (macOS style)**
- Calendar permission management
- Calendar selection/creation
- Contacts permission status (not yet used)
- Import window configuration
- Toggle calendar import on/off

### 🏗️ Architecture

**Navigation:** NavigationSplitView with sidebar (Awareness, People, Contexts, Inbox)

**Data Flow:**
```
Calendar App 
→ CalendarImportCoordinator 
→ MockEvidenceRuntimeStore.upsert()
→ EvidenceItem created/updated
→ InsightGeneratorV1 adds signals
→ AwarenessHost derives EvidenceBackedInsights
→ User reviews in Awareness & Inbox
```

**Core Models:**

- **EvidenceItem:** id, state, sourceUID ("eventkit:\<calendarItemIdentifier\>"), source, occurredAt, title, snippet, bodyText, signals, proposedLinks, linkedPeople, linkedContexts
- **EvidenceSignal:** kind, confidence, reason (explainable)
- **EvidenceBackedInsight:** message, confidence, evidence count, supporting items

**Key Files (~25 Swift files total):**
- `CalendarImportCoordinator.swift` - calendar event import
- `MockEvidenceRuntimeStore.swift` - Evidence storage & operations
- `EvidenceModels.swift` - core data models
- `AwarenessHost.swift` - Insight generation & UI
- `InboxHost.swift` - Inbox UI
- `SamSettingsView.swift` - Settings UI
- `AppShellView.swift` - NavigationSplitView layout

---

## Build & Run

**Requirements:**
- macOS target
- SwiftUI
- Sandbox enabled with Calendar & Contacts entitlements
- Info.plist usage descriptions for Calendar and Contacts access

**To run:**
1. Open Xcode project
2. Build and run
3. Grant Calendar permission in Settings
4. Create or select "SAM" calendar
5. Events from that calendar will import automatically

---

## Known Issues & Constraints

**Critical Constraints:**
- ❌ Do NOT use nested NavigationStacks inside NavigationSplitView
- ❌ Only ONE calendar import path (CalendarImportCoordinator only)
- ✅ Always use sourceUID format: `"eventkit:<calendarItemIdentifier>"`
- ✅ Prune logic must run when calendar changes
- Always use code complient with macOS 26+ for mac apps, and iOS 18+ for iOS apps

**Current Limitations:**
- Contacts integration not yet implemented (permission UI exists)
- Mail and Zoom integration not yet implemented
- InsightGenerator is currently rule-based (v1), not AI-powered

---

## Immediate Priorities

### ✅ Completed This Session (2/3/26)

1. **Consolidated to single calendar import path.**
   - Removed the old `importCalendarEvents` / `upsertEvidenceFromCalendar` methods from `MockEvidenceRuntimeStore` (the v0 path).
   - Removed the now-unused `import EventKit` from that file.
   - Rewired `SamSettingsView`'s "Import Now" button to call `CalendarImportCoordinator.shared.importNow()` instead of the old store method. The coordinator already guards on auth status, enabled toggle, and selected calendar — the redundant guards in Settings were removed.
   - **Invariant enforced:** `CalendarImportCoordinator` is the only path that writes calendar evidence. The store exposes only `upsert()` and `pruneCalendarEvidenceNotIn()`.

2. **Removed duplicate `MockContextStore` from `AppShellView.swift`.**
   - `enum MockContextStore` (with `all`, `byID`, `listItems`) was stranded in `AppShellView` but only `all` was ever referenced — by `MockContextRuntimeStore`'s seed initialiser.
   - `byID` and `listItems` on the static enum were completely unused; the live `MockContextRuntimeStore` already exposes identical observable properties.
   - Deleted the enum. Changed `MockContextRuntimeStore.all`'s initialiser to `[MockContexts.smithHousehold]` directly (the enum in `ContextDetailModel.swift` that was always the real seed source).

### 📋 Remaining Tasks (priority order)

3. **Wire or remove `autoSelectIfNeeded` in `PeopleListView`.**
   - The method and its `score()` helper exist but are never called. `ContextListView` does the equivalent via `.task { autoSelectIfNeeded() }`. Either add the same `.task` call, or delete the dead code.

4. **Contacts integration (read-only).**
   - Permission UI already exists in Settings → Contacts tab.
   - Next step: use `CNContactStore` to populate `participantHints` on calendar-imported evidence, and optionally seed `MockPeopleRuntimeStore` from real contacts.

5. **Replace `Mock*RuntimeStore` singletons with SwiftData.**
   - All three stores (`Evidence`, `People`, `Context`) are in-memory only — app restart loses everything.
   - SwiftData is the lightest path to persistence on macOS. Seed data should move to a one-time migration or "first launch" flow.

6. **Upgrade `InsightGeneratorV1` with on-device LLM (Foundation Models).**
   - Keyword rules are a solid baseline; an on-device model handles long-tail cases (implied referrals, tone shifts) without network or privacy risk.
   - Consult `FoundationModels-Using-on-device-LLM-in-your-app.md` when starting.

### 📝 Known Remaining Nits

- `cynthia` placeholder in `MockEvidenceRuntimeStore.seedIfNeeded()` — looked up then immediately discarded with `_ = cynthia`. Wire into a fourth seed evidence item or remove.
- `DateFormatter` in `InboxDetailView.formatDate()` and `SuggestedLinkRow.format()` is created per-call. Minor; a static formatter is an easy cleanup.

---

## Design Guidelines

**SwiftUI Best Practices:**
- macOS Human Interface Guidelines
- Use Inspectors and sheets, not alerts
- Local-first processing where possible
- Trust, transparency, reversibility in UX

**Code Style:**
- SwiftUI-first approach
- Clear separation of concerns (Coordinators, Stores, Views)
- Deterministic, explainable logic (especially for signals)
- With respect to incorporating LLM, consult Apple documentation FoundationModels-Using-on-device-LLM-in-your-app.md
- With repsect to UX, consult Apple documentation SwiftUI-Implementing-Liquid-Glass-Design.md
---

