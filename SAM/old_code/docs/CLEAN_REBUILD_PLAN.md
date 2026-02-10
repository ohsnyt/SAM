# SAM Clean Architecture Rebuild

**Date Started**: February 9, 2026  
**Status**: 🟡 In Progress  
**Approach**: Clean slate with old code archived as reference

---

## Why We're Doing This

**Problems with old codebase**:
- Scattered CNContact/EKEvent API calls with inconsistent key fetching
- Mixed concerns (views calling APIs, coordinators doing UI work)
- Concurrency errors from MainActor isolation scattered everywhere
- Directory structure became disorganized over time
- Every change broke existing code

**Solution**: Build from scratch with clear architectural boundaries.

---

## Archive Location

All existing code moved to: `SAM_crm/SAM_crm/old_code/`

```
old_code/
├── swift_files/          # All existing .swift files
├── views/                # View-related files
├── models/               # Model files
├── coordinators/         # Coordinator files
└── docs/                 # All .md documentation
```

**DO NOT DELETE** - Keep as reference during rebuild.

---

## New Architecture

### Principles

1. **Separation of Concerns**: Each layer has ONE job
2. **Explicit Dependencies**: Pass services/repos as parameters, no hidden globals
3. **Concurrency by Design**: Actors for services, @MainActor only for views
4. **Sendable Everywhere**: No passing CNContact/EKEvent across actor boundaries
5. **Test-Friendly**: Every layer can be tested independently

### Directory Structure

```
SAM_crm/SAM_crm/
├── App/
│   ├── SAMApp.swift                    # App entry point
│   └── SAMModelContainer.swift         # SwiftData container
│
├── Services/                           # 🆕 External API layer
│   ├── ContactsService.swift           # All CNContact operations
│   ├── CalendarService.swift           # All EKEvent operations
│   └── PermissionsService.swift        # Authorization management
│
├── Coordinators/                       # 🆕 Business logic orchestration
│   ├── ContactsImportCoordinator.swift # Orchestrates contacts import
│   ├── CalendarImportCoordinator.swift # Orchestrates calendar import
│   └── InsightGenerator.swift          # Generate insights from evidence
│
├── Repositories/                       # 🆕 SwiftData CRUD only
│   ├── PeopleRepository.swift          # CRUD for SamPerson
│   ├── EvidenceRepository.swift        # CRUD for SamEvidenceItem
│   └── ContextsRepository.swift        # CRUD for SamContext
│
├── Models/
│   ├── SwiftData/                      # @Model classes (persistent)
│   │   ├── SamPerson.swift
│   │   ├── SamEvidenceItem.swift
│   │   ├── SamContext.swift
│   │   ├── SamInsight.swift
│   │   └── SamNote.swift
│   │
│   └── DTOs/                           # 🆕 Data Transfer Objects (Sendable)
│       ├── ContactDTO.swift            # Sendable wrapper for CNContact
│       ├── EventDTO.swift              # Sendable wrapper for EKEvent
│       └── PersonDetailModel.swift     # Computed properties for views
│
├── Views/
│   ├── AppShellView.swift              # Main navigation container
│   │
│   ├── People/
│   │   ├── PeopleListView.swift
│   │   ├── PersonDetailView.swift
│   │   └── Components/
│   │       ├── ContactInfoSection.swift
│   │       └── FamilySection.swift
│   │
│   ├── Inbox/
│   │   ├── InboxListView.swift
│   │   └── InboxDetailView.swift
│   │
│   ├── Contexts/
│   │   ├── ContextListView.swift
│   │   └── ContextDetailView.swift
│   │
│   ├── Awareness/
│   │   └── AwarenessView.swift
│   │
│   └── Settings/
│       └── SettingsView.swift
│
└── Utilities/
    ├── DevLogger.swift
    └── Extensions/
        ├── Date+Extensions.swift
        └── String+Extensions.swift
```

---

## Build Order (Incremental Vertical Slices)

### ✅ Phase A: Foundation (Day 1)
**Goal**: Get app launching with empty window

- [ ] Create directory structure
- [ ] Copy `SAMModelContainer.swift` (no changes)
- [ ] Create minimal `SAMApp.swift`
- [ ] Create placeholder `AppShellView.swift`
- [ ] Copy essential `@Model` classes (SamPerson, SamContext, SamEvidenceItem)
- [ ] **Verify**: App launches, shows empty window

### 🟡 Phase B: Services Layer (Day 2)
**Goal**: Prove external API access works cleanly

- [ ] Create `Services/ContactsService.swift` (actor-based)
- [ ] Create `Models/DTOs/ContactDTO.swift` (Sendable)
- [ ] Create `Services/PermissionsService.swift`
- [ ] Create test view that fetches one contact
- [ ] **Verify**: Can fetch contact photo and display it

### ⬜ Phase C: Data Layer (Day 3)
**Goal**: Import contacts into SwiftData

- [ ] Create `Repositories/PeopleRepository.swift`
- [ ] Create `Coordinators/ContactsImportCoordinator.swift`
- [ ] Wire up permission flow in Settings
- [ ] **Verify**: Contacts from SAM group appear in SwiftData

### ⬜ Phase D: First Feature - People (Day 4)
**Goal**: Complete vertical slice from API → Storage → UI

- [ ] Create `Views/People/PeopleListView.swift`
- [ ] Create `Views/People/PersonDetailView.swift`
- [ ] Update `AppShellView.swift` with NavigationSplitView
- [ ] **Verify**: Can view list of people, tap to see details with contact photo

### ⬜ Phase E: Calendar & Evidence (Day 5)
**Goal**: Calendar events create Evidence items

- [ ] Create `Services/CalendarService.swift`
- [ ] Create `Models/DTOs/EventDTO.swift`
- [ ] Create `Repositories/EvidenceRepository.swift`
- [ ] Create `Coordinators/CalendarImportCoordinator.swift`
- [ ] **Verify**: Events from SAM calendar appear as Evidence

### ⬜ Phase F: Inbox (Day 6)
- [ ] Create `Views/Inbox/InboxListView.swift`
- [ ] Create `Views/Inbox/InboxDetailView.swift`
- [ ] **Verify**: Can see evidence items, mark as reviewed

### ⬜ Phase G: Contexts (Day 7)
- [ ] Create `Repositories/ContextsRepository.swift`
- [ ] Create `Views/Contexts/ContextListView.swift`
- [ ] Create `Views/Contexts/ContextDetailView.swift`
- [ ] **Verify**: Can create household/business contexts

### ⬜ Phase H: Insights (Day 8)
- [ ] Create `Coordinators/InsightGenerator.swift`
- [ ] Create `Views/Awareness/AwarenessView.swift`
- [ ] Wire up insight generation after imports
- [ ] **Verify**: Insights appear in Awareness tab

### ⬜ Phase I: Settings & Polish (Day 9-10)
- [ ] Create `Views/Settings/SettingsView.swift`
- [ ] Add permission management UI
- [ ] Add calendar/contact group selection
- [ ] Add keyboard shortcuts
- [ ] **Verify**: All settings functional

---

## Migration Reference: Old → New

### File Mapping

| Old Location | New Location | Changes |
|--------------|--------------|---------|
| `ContactsImportCoordinator.swift` | `Coordinators/ContactsImportCoordinator.swift` | Uses `ContactsService` instead of direct CNContactStore |
| `CalendarImportCoordinator.swift` | `Coordinators/CalendarImportCoordinator.swift` | Uses `CalendarService`, resolver logic moved to service |
| `PersonDetailView.swift` | `Views/People/PersonDetailView.swift` | Works with `ContactDTO`, no direct CNContact access |
| `ContactValidator.swift` | **DELETED** | Logic moved into `ContactsService` |
| `ContactsResolver` (in CalendarImportCoordinator) | **DELETED** | Logic moved into `CalendarService.resolveAttendees()` |
| `PeopleRepository.swift` | `Repositories/PeopleRepository.swift` | No direct CNContact access, receives DTOs |
| `MeCardManager.swift` | Merged into `ContactsService` | Uses service pattern |

### Key Patterns to Follow

#### ❌ Old Pattern (BAD)
```swift
// View directly accesses CNContactStore
struct PersonDetailView: View {
    let person: SamPerson
    @State private var contact: CNContact?
    
    var body: some View {
        Text(person.displayName)
            .task {
                let store = CNContactStore()  // ⚠️ Creates new store!
                contact = try? store.unifiedContact(...)  // ⚠️ May trigger permission dialog!
            }
    }
}
```

#### ✅ New Pattern (GOOD)
```swift
// View uses service and DTO
struct PersonDetailView: View {
    let person: SamPerson
    @State private var contactDetails: ContactDTO?
    
    var body: some View {
        Text(person.displayName)
            .task {
                contactDetails = await ContactsService.shared.fetchContact(
                    identifier: person.contactIdentifier,
                    keys: .detail  // ✅ Standardized key set
                )
            }
    }
}
```

---

## Testing Strategy

Each layer should be testable independently:

### Services
```swift
@Test("ContactsService fetches contact")
func testContactFetch() async throws {
    let contact = await ContactsService.shared.fetchContact(
        identifier: "test-id",
        keys: .minimal
    )
    #expect(contact != nil)
}
```

### Repositories
```swift
@Test("PeopleRepository upserts person")
func testUpsert() throws {
    let repo = PeopleRepository(container: inMemoryContainer)
    let dto = ContactDTO(identifier: "123", givenName: "John", familyName: "Doe")
    
    try repo.upsert(contact: dto)
    
    let people = try repo.fetchAll()
    #expect(people.count == 1)
    #expect(people.first?.displayName == "John Doe")
}
```

### Coordinators
```swift
@Test("ContactsImportCoordinator imports contacts")
func testImport() async throws {
    let mockService = MockContactsService()
    let coordinator = ContactsImportCoordinator(
        contactsService: mockService,
        repository: testRepository
    )
    
    await coordinator.importNow()
    
    #expect(mockService.fetchCallCount == 1)
}
```

---

## Concurrency Guidelines

### Services: Use `actor`
```swift
actor ContactsService {
    func fetchContact(...) async -> ContactDTO? { ... }
}
```

### Coordinators: Use `@MainActor` only if needed
```swift
// If it only orchestrates async calls, no @MainActor needed
final class ContactsImportCoordinator {
    func importNow() async { ... }
}
```

### Repositories: `@MainActor` (because SwiftData ModelContext is)
```swift
@MainActor
final class PeopleRepository {
    func upsert(contact: ContactDTO) throws { ... }
}
```

### Views: `@MainActor` implicit
```swift
struct PersonDetailView: View {
    // All View code is implicitly @MainActor
}
```

---

## Checklist for Each New Feature

Before adding a feature, ask:

- [ ] Does this need external API access? → Create method in appropriate Service
- [ ] Does this need persistent storage? → Create method in appropriate Repository
- [ ] Does this need business logic coordination? → Create/update Coordinator
- [ ] Does this need UI? → Create View that uses DTOs
- [ ] Is all data crossing actor boundaries `Sendable`?
- [ ] Are all CNContact/EKEvent accesses going through Services?
- [ ] Can this be tested without launching the full app?

---

## Emergency Recovery

If something breaks and you need to reference old code:

1. **Find old implementation**: Check `old_code/swift_files/`
2. **Don't copy-paste directly**: Extract the logic, rewrite to fit new architecture
3. **Ask**: "Which layer does this belong in?"

---

## Success Metrics

We'll know the rebuild succeeded when:

- [ ] No direct CNContactStore/EKEventStore access outside Services/
- [ ] No `nonisolated(unsafe)` escape hatches
- [ ] All concurrency warnings resolved
- [ ] Each layer has < 10 files (cohesive responsibilities)
- [ ] New features take < 1 hour to add (vs. full day of debugging)
- [ ] Tests run in < 2 seconds (fast feedback loop)

---

## Next Steps

1. **You**: Create `old_code/` directory and move existing files
2. **Me**: Generate the Phase A foundation files
3. **Together**: Build Phase B services layer and verify it works
4. **Iterate**: One phase per day until feature-complete

Ready to start? Let me know when you've archived the old code! 🚀
