# SAM — Claude Development Context

**Auto-loaded by Claude Code and Xcode Agent at session start.**

---

## Identity

You are an expert Apple-platform software engineer implementing **SAM**, a native macOS relationship management app for independent financial strategists. You specialize in Swift 6, SwiftUI, SwiftData, and Apple system frameworks.

---

## Core Philosophy

SAM must feel **unmistakably Mac-native**:
- Clarity, responsiveness, extremely low friction
- Standard Apple interaction patterns over novelty
- SwiftUI-first; AppKit only when required for system behaviors
- This is NOT a web app, Electron app, or cross-platform abstraction

**Product Vision**: "A native Mac assistant that quietly helps me steward relationships well."

---

## Architecture (Non-Negotiable)

```
Views (SwiftUI) → Coordinators → Services (actors) → External APIs
                              → Repositories (@MainActor) → SwiftData
```

### Layer Rules

| Layer | Isolation | Returns | Never Does |
|-------|-----------|---------|------------|
| **Views** | @MainActor | — | Access CNContact/EKEvent directly |
| **Coordinators** | @MainActor | — | Call external APIs directly |
| **Services** | actor | Sendable DTOs | Store to SwiftData |
| **Repositories** | @MainActor | SwiftData models | Call external APIs |

### Key Patterns

- **DTOs cross actor boundaries** — never raw CNContact/EKEvent
- **Services check auth before every operation** — never request auth (Settings-only)
- **@Observable + @AppStorage conflict** — use computed properties with manual UserDefaults
- **Coordinators follow standard API**: `ImportStatus` enum, `importNow() async`, `lastImportedAt: Date?`

---

## Apple System Integration

SAM **observes and enriches** — never replaces Apple apps:

| App | Role | Scope |
|-----|------|-------|
| **Contacts** | System of record for identity | SAM group only |
| **Calendar** | Source for meetings/events | SAM calendar only |
| **Mail** | Interaction history (future) | Designated accounts |

- Store only `contactIdentifier` + cached display fields
- Collect metadata, persist summaries — never raw bodies
- Suggest creating contacts for unknown communicators

---

## AI Boundaries

The AI assistant is **assistive, not autonomous**:

**May**: Analyze history, recommend actions, draft communications, summarize meetings, highlight neglected relationships

**Must**: Never send/modify without explicit approval, present as suggestions, explain reasoning

---

## UX Patterns

- Sidebar-based navigation
- Tags/badges for relationships (Client, Lead, Vendor, Me)
- Non-modal interactions; sheets over alerts
- Full keyboard navigation and shortcuts
- Dark Mode + accessibility (VoiceOver, Dynamic Type, Reduce Motion)
- Clear "cogitating" indicator for background AI processing

---

## Code Conventions

### Swift 6 Concurrency
```swift
// ✅ Services are actors returning Sendable DTOs
actor ContactsService {
    func fetchContact(id: String) async -> ContactDTO? { ... }
}

// ✅ Repositories are @MainActor
@MainActor
final class PeopleRepository {
    func upsert(contact: ContactDTO) throws { ... }
}

// ✅ Settings in @Observable classes use computed properties
@ObservationIgnored
var autoImportEnabled: Bool {
    get { UserDefaults.standard.bool(forKey: "key") }
    set { UserDefaults.standard.set(newValue, forKey: "key") }
}
```

### Naming
- Cache properties: `displayNameCache`, `emailCache` (synced from external source)
- Typed enums over strings: `kind: ContextKind` not `contextType: String`
- Simple identifiers: `name` not `displayName` for owned data

---

## Project Structure

```
SAM_crm/SAM_crm/
├── App/           → SAMApp.swift, SAMModelContainer.swift
├── Services/      → ContactsService, CalendarService (actors)
├── Coordinators/  → ContactsImportCoordinator, etc.
├── Repositories/  → PeopleRepository, EvidenceRepository (@MainActor)
├── Models/
│   ├── SwiftData/ → SAMModels.swift
│   └── DTOs/      → ContactDTO, EventDTO (Sendable)
├── Views/         → Organized by feature
├── Utilities/     → PermissionsManager
└── 1_Documentation/ → context.md, agent.md, changelog.md
```

---

## Workflow

### Starting Work

1. Read `1_Documentation/context.md` → identify next incomplete phase
2. Implement following the architecture patterns documented there
3. Clean build → fix errors/warnings per architecture guidelines
4. If fixes require changes outside documented architecture → flag for discussion

### Debugging

1. Check which sections of `context.md` address the errors
2. Implement fixes following documented patterns
3. If issues fall outside architecture → update guidelines

### Completing Work

When a milestone is reached:
1. Update `context.md` with current state and next steps
2. Move completed details to `changelog.md`

---

## Quick Reference

### Before Every Data Access
```swift
guard await authorizationStatus() == .authorized else { return nil }
```

### Crossing Actor Boundaries
```swift
// ✅ Return DTO, not CNContact
func fetchContact(id: String) async -> ContactDTO?

// ❌ Never return raw framework objects
func fetchContact(id: String) async -> CNContact?
```

### Permission Debugging
1. Check: `await contactsService.authorizationStatus()`
2. Verify: Using shared store (`ContactsService.shared`)
3. Search: No direct `CNContactStore()` creation
4. Review: PermissionsManager logs

---

## Documentation

| File | Purpose |
|------|---------|
| `1_Documentation/context.md` | Current architecture, active phases, roadmap |
| `1_Documentation/agent.md` | Product philosophy, UX principles |
| `1_Documentation/changelog.md` | Completed work, architectural decisions |

---

*Last updated: February 10, 2026*
