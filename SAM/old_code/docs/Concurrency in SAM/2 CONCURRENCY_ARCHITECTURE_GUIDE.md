# SAM CRM - Concurrency Architecture Guide

## Document Purpose

This guide provides a comprehensive overview of how concurrency is structured throughout the SAM CRM application, including actor isolation boundaries, data model access patterns, and Swift 6 compliance strategies.

**Last Updated:** February 9, 2026  
**Swift Version:** Swift 6.0+  
**Minimum Platform:** macOS 14.0+

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Actor Isolation Model](#actor-isolation-model)
3. [Data Model Access Patterns](#data-model-access-patterns)
4. [SwiftData Threading Rules](#swiftdata-threading-rules)
5. [MainActor Coordination Layer](#mainactor-coordination-layer)
6. [Background Processing Actors](#background-processing-actors)
7. [Common Concurrency Patterns](#common-concurrency-patterns)
8. [Troubleshooting Guide](#troubleshooting-guide)

---

## Architecture Overview

### High-Level Design

SAM CRM uses a **multi-actor architecture** with clear isolation boundaries:

```
┌─────────────────────────────────────────────────────────────────────┐
│                          MainActor Layer                             │
│  ┌──────────────────────┐  ┌──────────────────────┐                │
│  │ UI Coordinators      │  │ Observable Managers   │                │
│  │ • CalendarImport...  │  │ • PermissionsManager  │                │
│  │ • ContactsImport...  │  │ • EvidenceRepository  │                │
│  └──────────────────────┘  └──────────────────────┘                │
│               │                       │                              │
│               └───────┬───────────────┘                              │
│                       │ Fire-and-forget async calls                  │
└───────────────────────┼──────────────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Background Actor Layer                            │
│  ┌────────────────────────┐    ┌──────────────────────────┐        │
│  │ DebouncedInsightRunner │───▶│  InsightGenerator        │        │
│  │ • Task management      │    │  • SwiftData processing  │        │
│  │ • Debouncing           │    │  • Evidence analysis     │        │
│  │ • Cancellation         │    │  • Insight creation      │        │
│  └────────────────────────┘    └──────────────────────────┘        │
└─────────────────────────────────────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────────────┐
│                       SwiftData Layer                                │
│  ┌─────────────────────────────────────────────────────────┐       │
│  │  SAMModelContainer (nonisolated static)                 │       │
│  │  • Single shared ModelContainer                          │       │
│  │  • ModelContext created per-actor                        │       │
│  │  • No cross-actor context sharing                        │       │
│  └─────────────────────────────────────────────────────────┘       │
└─────────────────────────────────────────────────────────────────────┘
```

### Key Principles

1. **UI stays on MainActor** - All UI-facing types use `@MainActor` isolation
2. **Heavy work moves to actors** - Long-running operations run on background actors
3. **Fire-and-forget async** - MainActor code delegates to actors without blocking
4. **ModelContext per actor** - Each actor creates its own ModelContext
5. **No shared mutable state** - All cross-actor communication uses `await`

---

## Actor Isolation Model

### MainActor Types

All types that interact with SwiftUI or coordinate user-facing operations are `@MainActor`:

```swift
@MainActor
final class CalendarImportCoordinator {
    static let shared = CalendarImportCoordinator()
    // All properties and methods are MainActor-isolated
}

@MainActor
@Observable
final class PermissionsManager {
    static let shared = PermissionsManager()
    private(set) var calendarStatus: EKAuthorizationStatus
    // Observable properties for SwiftUI
}

@MainActor
@Observable
final class EvidenceRepository {
    static let shared = EvidenceRepository()
    // Repository pattern with MainActor isolation
}
```

### Background Actors

Heavy computation and I/O operations use dedicated actors:

```swift
actor DebouncedInsightRunner {
    static let shared = DebouncedInsightRunner()
    private var runningTask: Task<Void, Never>?
    
    func run() {
        runningTask?.cancel()
        runningTask = Task {
            try? await Task.sleep(for: .seconds(1.0))
            // Heavy work here
        }
    }
}

actor InsightGenerator {
    private let context: ModelContext
    
    init(context: ModelContext) {
        self.context = context
    }
    
    func generatePendingInsights() async {
        // SwiftData operations isolated to this actor
    }
}
```

### Nonisolated Types

Types that have no mutable state or are thread-safe can be `nonisolated`:

```swift
// Enum with static methods
enum SAMModelContainer {
    nonisolated static let shared: ModelContainer = { ... }()
    nonisolated static func newContext() -> ModelContext { ... }
}

// Value types (structs) are implicitly nonisolated if they have no actor requirements
struct ParticipantHint: Codable {
    let displayName: String
    let isOrganizer: Bool
}
```

---

## Data Model Access Patterns

### SwiftData Model Classes

All `@Model` classes are **NOT Sendable** by default and should only be accessed from a single actor at a time:

```swift
@Model
public final class SamPerson {
    @Attribute(.unique) public var id: UUID
    public var displayName: String
    public var contactIdentifier: String?
    // ... other properties
}

@Model
public final class SamContext {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var kind: ContextKind
    // ... other properties
}

@Model
public final class SamEvidenceItem {
    @Attribute(.unique) public var id: UUID
    public var stateRawValue: String
    public var occurredAt: Date
    // ... other properties
}

@Model
public final class SamInsight {
    @Attribute(.unique) public var id: UUID
    public var kind: InsightKind
    public var message: String
    public var basedOnEvidence: [SamEvidenceItem]
    // ... other properties
}
```

### Model Access Rules

#### ✅ CORRECT: Same-Actor Access

```swift
@MainActor
func updatePerson() throws {
    let ctx = ModelContext(SAMModelContainer.shared)
    let descriptor = FetchDescriptor<SamPerson>()
    let people = try ctx.fetch(descriptor)
    
    for person in people {
        person.displayName = "Updated"  // ✅ Same actor
    }
    
    try ctx.save()
}
```

#### ✅ CORRECT: Actor-Isolated Context

```swift
actor DataProcessor {
    private let context: ModelContext
    
    init() {
        // Create context once when actor is initialized
        self.context = ModelContext(SAMModelContainer.shared)
    }
    
    func processData() async throws {
        let descriptor = FetchDescriptor<SamEvidenceItem>()
        let items = try context.fetch(descriptor)
        
        for item in items {
            // Process item - all on this actor
            item.state = .done
        }
        
        try context.save()
    }
}
```

#### ❌ WRONG: Cross-Actor Model Access

```swift
@MainActor
func fetchPeople() throws -> [SamPerson] {
    let ctx = ModelContext(SAMModelContainer.shared)
    return try ctx.fetch(FetchDescriptor<SamPerson>())
}

actor Worker {
    func processAllPeople() async throws {
        let people = try await fetchPeople()  // ❌ Models fetched on MainActor
        
        for person in people {
            person.displayName = "Updated"  // ❌ ERROR: Accessing MainActor-fetched model from nonisolated actor
        }
    }
}
```

#### ✅ CORRECT: Pass IDs, Not Models

```swift
@MainActor
func getPersonIDs() throws -> [UUID] {
    let ctx = ModelContext(SAMModelContainer.shared)
    let people = try ctx.fetch(FetchDescriptor<SamPerson>())
    return people.map(\.id)  // ✅ Pass value types only
}

actor Worker {
    private let context: ModelContext
    
    init() {
        self.context = ModelContext(SAMModelContainer.shared)
    }
    
    func processPeople(_ ids: [UUID]) async throws {
        for id in ids {
            // ✅ Fetch on this actor's context
            let descriptor = FetchDescriptor<SamPerson>(
                predicate: #Predicate { $0.id == id }
            )
            if let person = try context.fetch(descriptor).first {
                person.displayName = "Updated"  // ✅ Safe: fetched on this actor
            }
        }
        try context.save()
    }
}
```

---

## SwiftData Threading Rules

### Rule 1: One ModelContext Per Actor

**Never share a ModelContext across actors.**

```swift
// ❌ WRONG: Shared context
let sharedContext = ModelContext(SAMModelContainer.shared)

@MainActor
func mainActorWork() {
    try? sharedContext.save()  // ❌ Used on MainActor
}

actor Worker {
    func doWork() async {
        try? sharedContext.save()  // ❌ Used on Worker actor - DATA RACE!
    }
}
```

```swift
// ✅ CORRECT: Context per actor
@MainActor
func mainActorWork() {
    let ctx = ModelContext(SAMModelContainer.shared)  // ✅ MainActor context
    try? ctx.save()
}

actor Worker {
    private let context: ModelContext
    
    init() {
        self.context = ModelContext(SAMModelContainer.shared)  // ✅ Worker actor context
    }
    
    func doWork() async {
        try? context.save()
    }
}
```

### Rule 2: Models Don't Cross Actors

**Models fetched on one actor must not be accessed from another actor.**

The compiler will prevent this in most cases, but be aware when using `Any` or existentials.

### Rule 3: Use Predicates for Filtering

**Push filtering to the database, not to Swift memory.**

```swift
// ❌ WRONG: In-memory filtering
func needsReview() throws -> [SamEvidenceItem] {
    let all = try context.fetch(FetchDescriptor<SamEvidenceItem>())
    return all.filter { $0.stateRawValue == "needsReview" }  // ❌ Loads everything
}

// ✅ CORRECT: Database filtering
func needsReview() throws -> [SamEvidenceItem] {
    let predicate = #Predicate<SamEvidenceItem> { 
        $0.stateRawValue == "needsReview" 
    }
    let descriptor = FetchDescriptor<SamEvidenceItem>(
        predicate: predicate,
        sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
    )
    return try context.fetch(descriptor)  // ✅ Database does the work
}
```

### Rule 4: Value Types for Cross-Actor Communication

**Use structs/enums to pass data between actors, not model classes.**

```swift
// ✅ Value type for communication
struct PersonSummary: Sendable {
    let id: UUID
    let name: String
    let email: String?
}

@MainActor
func getPersonSummaries() throws -> [PersonSummary] {
    let ctx = ModelContext(SAMModelContainer.shared)
    let people = try ctx.fetch(FetchDescriptor<SamPerson>())
    return people.map { PersonSummary(id: $0.id, name: $0.displayName, email: $0.email) }
}

actor Reporter {
    func generateReport(_ summaries: [PersonSummary]) async {
        // ✅ Safe: working with value types
        for summary in summaries {
            print("\(summary.name): \(summary.email ?? "no email")")
        }
    }
}
```

---

## MainActor Coordination Layer

### Purpose

The MainActor layer coordinates user-facing operations and delegates heavy work to background actors.

### Key Pattern: Fire-and-Forget Async

When MainActor code needs to trigger background work, use fire-and-forget `Task`:

```swift
@MainActor
final class CalendarImportCoordinator {
    func kick(reason: String) {
        // Cancel any pending work
        debounceTask?.cancel()
        
        // Fire and forget - don't block MainActor
        debounceTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            await importIfNeeded(reason: reason)
        }
    }
    
    private func importCalendarEvidence() async {
        // Do import work...
        
        // Trigger insight generation (fire and forget)
        Task {
            await DebouncedInsightRunner.shared.run()
        }
    }
}
```

### Observable Managers

Use `@Observable` (not `ObservableObject`) for SwiftUI integration:

```swift
@MainActor
@Observable
final class PermissionsManager {
    private(set) var calendarStatus: EKAuthorizationStatus
    private(set) var contactsStatus: CNAuthorizationStatus
    
    // SwiftUI automatically observes changes
    func refreshStatus() {
        calendarStatus = EKEventStore.authorizationStatus(for: .event)
        contactsStatus = CNContactStore.authorizationStatus(for: .contacts)
    }
}

// In SwiftUI:
struct SettingsView: View {
    @Environment(PermissionsManager.self) private var permissions
    
    var body: some View {
        Text(permissions.calendarStatusText())  // ✅ Automatic observation
    }
}
```

### Async Notification Sequences

Replace `@objc` selectors with async sequences:

```swift
// ❌ OLD WAY (Swift 5)
private func setupObservers() {
    NotificationCenter.default.addObserver(
        self,
        selector: #selector(handleChange),
        name: .EKEventStoreChanged,
        object: nil
    )
}

@objc private func handleChange() {
    refreshStatus()
}

// ✅ NEW WAY (Swift 6)
private func setupObservers() {
    Task {
        for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged) {
            refreshStatus()  // Already on MainActor
        }
    }
}
```

---

## Background Processing Actors

### Debounced Work Pattern

Use actors to manage task lifecycle and debouncing:

```swift
actor DebouncedInsightRunner {
    static let shared = DebouncedInsightRunner()
    
    private var runningTask: Task<Void, Never>?
    
    func run() {
        // Cancel any existing task
        runningTask?.cancel()
        
        // Start new task
        runningTask = Task {
            // Debounce period
            try? await Task.sleep(for: .seconds(1.0))
            
            // Check cancellation
            guard !Task.isCancelled else { return }
            
            // Do work
            let ctx = SAMModelContainer.newContext()
            let generator = InsightGenerator(context: ctx)
            await generator.generatePendingInsights()
        }
    }
}

// Called from MainActor:
Task {
    await DebouncedInsightRunner.shared.run()
}
```

### Heavy Processing Actor

Isolate long-running operations:

```swift
actor InsightGenerator {
    private let context: ModelContext
    
    init(context: ModelContext) {
        self.context = context
    }
    
    func generatePendingInsights() async {
        // Fetch data
        let fetch = FetchDescriptor<SamEvidenceItem>()
        let evidence = (try? context.fetch(fetch)) ?? []
        
        // Process (CPU-intensive work)
        let grouped = groupBySignals(evidence)
        
        // Create insights
        for (key, items) in grouped {
            let insight = createInsight(for: items)
            context.insert(insight)
        }
        
        try? context.save()
    }
}
```

---

## Common Concurrency Patterns

### Pattern 1: Coordinator Triggers Background Work

```swift
@MainActor
final class SomeCoordinator {
    func triggerWork() {
        Task {
            await BackgroundActor.shared.doWork()
        }
    }
}
```

### Pattern 2: Actor Processes Data with Own Context

```swift
actor DataProcessor {
    private let context: ModelContext
    
    init() {
        self.context = ModelContext(SAMModelContainer.shared)
    }
    
    func process() async throws {
        let items = try context.fetch(FetchDescriptor<SomeModel>())
        // Process items...
        try context.save()
    }
}
```

### Pattern 3: Pass IDs, Fetch Separately

```swift
@MainActor
func getWorkItems() throws -> [UUID] {
    let ctx = ModelContext(SAMModelContainer.shared)
    let items = try ctx.fetch(FetchDescriptor<SomeModel>())
    return items.map(\.id)
}

actor Worker {
    private let context: ModelContext
    
    init() {
        self.context = ModelContext(SAMModelContainer.shared)
    }
    
    func process(ids: [UUID]) async throws {
        for id in ids {
            let descriptor = FetchDescriptor<SomeModel>(
                predicate: #Predicate { $0.id == id }
            )
            if let item = try context.fetch(descriptor).first {
                // Process item
            }
        }
    }
}
```

### Pattern 4: Parallel Processing with Task Groups

```swift
nonisolated func resolveContacts(_ identifiers: [String]) async -> [ContactData] {
    await withTaskGroup(of: ContactData?.self) { group in
        for id in identifiers {
            group.addTask(priority: .utility) {
                await resolveContact(id)
            }
        }
        
        var results: [ContactData] = []
        for await result in group {
            if let result { results.append(result) }
        }
        return results
    }
}
```

### Pattern 5: Offload Heavy Work with @concurrent

```swift
nonisolated struct ImageProcessor {
    @concurrent
    func process(data: Data) async -> ProcessedImage? {
        // This always runs on concurrent thread pool
        // Heavy CPU work here
        return processImage(data)
    }
}

// Called from MainActor:
let processed = await ImageProcessor().process(data: imageData)
```

---

## Troubleshooting Guide

### Error: "Passing closure as a 'sending' parameter risks causing data races"

**Cause:** Capturing MainActor-isolated properties in a Task closure.

```swift
@MainActor
final class MyCoordinator {
    private let repository = EvidenceRepository.shared  // MainActor-isolated
    
    func doWork() {
        Task {
            // ❌ ERROR: Capturing 'self.repository' in closure
            await repository.someMethod()
        }
    }
}
```

**Solution 1:** Make the entire method async:

```swift
@MainActor
final class MyCoordinator {
    private let repository = EvidenceRepository.shared
    
    func doWork() async {  // ✅ Async method
        await repository.someMethod()  // ✅ Direct call
    }
}
```

**Solution 2:** Copy the reference before Task:

```swift
@MainActor
final class MyCoordinator {
    private let repository = EvidenceRepository.shared
    
    func doWork() {
        let repo = repository  // ✅ Copy to local
        Task {
            await repo.someMethod()  // ✅ Uses local copy
        }
    }
}
```

**Solution 3:** Use nonisolated members:

```swift
@MainActor
final class MyCoordinator {
    nonisolated static let repository = EvidenceRepository.shared  // ✅ nonisolated
    
    func doWork() {
        Task {
            await Self.repository.someMethod()  // ✅ Static access
        }
    }
}
```

### Error: "Expression is 'async' but is not marked with 'await'"

**Cause:** Calling actor methods without `await`.

```swift
actor MyActor {
    func doWork() { }
}

func caller() {
    MyActor().doWork()  // ❌ ERROR: Missing await
}
```

**Solution:** Add `await` and make caller `async`:

```swift
func caller() async {
    await MyActor().doWork()  // ✅
}
```

### Error: "Main actor-isolated property cannot be referenced from a non-isolated context"

**Cause:** Accessing `@MainActor` properties from non-MainActor code.

```swift
@MainActor
final class Manager {
    var state: String = ""
}

actor Worker {
    func work(manager: Manager) {
        print(manager.state)  // ❌ ERROR: Accessing MainActor property
    }
}
```

**Solution:** Make the accessing code `@MainActor` or use async access:

```swift
actor Worker {
    func work(manager: Manager) async {
        let state = await MainActor.run { manager.state }  // ✅
        print(state)
    }
}
```

### Error: "Capture of 'self' with non-sendable type in a `@Sendable` closure"

**Cause:** Capturing non-Sendable types in concurrent contexts.

```swift
final class MyClass {
    var value: Int = 0
    
    func doWork() {
        Task {
            value += 1  // ❌ ERROR: MyClass is not Sendable
        }
    }
}
```

**Solution 1:** Mark the class as `@MainActor`:

```swift
@MainActor
final class MyClass {
    var value: Int = 0
    
    func doWork() {
        Task {
            value += 1  // ✅ All on MainActor
        }
    }
}
```

**Solution 2:** Use an actor:

```swift
actor MyActor {
    var value: Int = 0
    
    func doWork() async {
        value += 1  // ✅ Actor-isolated
    }
}
```

---

## Summary

### Quick Reference

| Scenario | Pattern |
|----------|---------|
| UI coordination | `@MainActor` class |
| Background processing | `actor` class |
| Observable state | `@MainActor @Observable` |
| Database access | Create `ModelContext` per actor |
| Cross-actor communication | Pass value types (IDs, structs) |
| Heavy CPU work | `@concurrent` function |
| Fire-and-forget | `Task { await actor.method() }` |
| Notification observing | Async sequence in `Task` |

### Key Takeaways

1. ✅ **MainActor for UI** - All UI-facing code stays on MainActor
2. ✅ **Actors for heavy work** - Long operations run on background actors
3. ✅ **ModelContext per actor** - Never share contexts across actors
4. ✅ **Value types between actors** - Pass IDs, not model objects
5. ✅ **Fire-and-forget** - Don't block MainActor waiting for background work
6. ✅ **@Observable not ObservableObject** - Use Swift 6 native observation
7. ✅ **Async sequences not @objc** - Modern notification handling
8. ✅ **Predicates not filters** - Push filtering to database

---

**End of Concurrency Architecture Guide**
