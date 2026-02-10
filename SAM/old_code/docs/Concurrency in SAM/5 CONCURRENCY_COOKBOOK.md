# Swift 6 Concurrency Cookbook - SAM CRM

## Introduction

This cookbook provides copy-paste-ready solutions for common concurrency scenarios in SAM CRM. Each recipe includes:
- ✅ Working code you can adapt
- ❌ Anti-patterns to avoid
- 📝 Explanation of why it works

---

## Table of Contents

1. [Creating a New Coordinator](#recipe-1-creating-a-new-coordinator)
2. [Creating a New Background Actor](#recipe-2-creating-a-new-background-actor)
3. [Adding a New Observable Manager](#recipe-3-adding-a-new-observable-manager)
4. [Querying SwiftData](#recipe-4-querying-swiftdata)
5. [Passing Data Between Actors](#recipe-5-passing-data-between-actors)
6. [Handling Notifications](#recipe-6-handling-notifications)
7. [Debouncing Work](#recipe-7-debouncing-work)
8. [Task Groups for Parallel Work](#recipe-8-task-groups-for-parallel-work)
9. [Heavy CPU-Bound Work](#recipe-9-heavy-cpu-bound-work)
10. [Updating Models from Background](#recipe-10-updating-models-from-background)

---

## Recipe 1: Creating a New Coordinator

**Use Case:** You need a coordinator that handles user-facing operations and delegates to background actors.

### ✅ CORRECT Pattern

```swift
import Foundation
import SwiftUI

@MainActor
final class MyFeatureCoordinator {
    
    // Singleton instance
    static let shared = MyFeatureCoordinator()
    
    // Make shared references nonisolated to avoid capture issues
    nonisolated private let dataService = SomeDataService.shared
    nonisolated private let permissions = PermissionsManager.shared
    
    // AppStorage for user preferences (automatically MainActor)
    @AppStorage("myfeature.enabled") private var isEnabled: Bool = true
    
    // Mutable state stays MainActor-isolated
    private var activeTask: Task<Void, Never>?
    
    // Private init for singleton
    private init() {
        setupObservers()
    }
    
    // Public API - trigger work
    func triggerImport() {
        activeTask?.cancel()
        
        activeTask = Task { @MainActor in
            // Debounce if needed
            try? await Task.sleep(for: .seconds(1.0))
            
            // Check cancellation
            guard !Task.isCancelled else { return }
            
            // Delegate to background
            await performImport()
        }
    }
    
    // Actual work
    private func performImport() async {
        guard isEnabled else { return }
        guard permissions.hasRequiredPermissions else { return }
        
        // Delegate heavy work to background actor
        Task {
            await BackgroundProcessor.shared.process()
        }
    }
    
    private func setupObservers() {
        // Use async sequences for notifications
        Task {
            for await _ in NotificationCenter.default.notifications(named: .someSystemEvent) {
                triggerImport()
            }
        }
    }
}
```

### ❌ ANTI-PATTERNS

```swift
// ❌ DON'T: MainActor-isolated properties captured in Task
@MainActor
final class BadCoordinator {
    private let service = SomeService.shared  // ❌ MainActor-isolated
    
    func work() {
        Task {
            await service.method()  // ❌ Capture error
        }
    }
}

// ❌ DON'T: Missing @MainActor annotation
final class BadCoordinator {
    @AppStorage("key") var value: Bool = true  // ❌ @AppStorage requires MainActor
}

// ❌ DON'T: Blocking MainActor with heavy work
@MainActor
final class BadCoordinator {
    func work() async {
        // ❌ Heavy work blocking MainActor
        let result = performExpensiveCalculation()
    }
}
```

---

## Recipe 2: Creating a New Background Actor

**Use Case:** You need an actor to perform heavy processing off the main thread.

### ✅ CORRECT Pattern

```swift
import Foundation
import SwiftData

actor MyBackgroundProcessor {
    
    // Singleton if needed
    static let shared = MyBackgroundProcessor()
    
    // Actor-isolated ModelContext
    private let context: ModelContext
    
    // Actor-isolated state
    private var isProcessing = false
    private var lastProcessedAt: Date?
    
    init() {
        // Create context once at init
        self.context = SAMModelContainer.newContext()
    }
    
    // Public async API
    func process() async throws {
        // Prevent concurrent processing
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }
        
        // Fetch data on this actor's context
        let descriptor = FetchDescriptor<SomeModel>(
            predicate: #Predicate { $0.needsProcessing == true },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        
        let items = try context.fetch(descriptor)
        
        // Process each item
        for item in items {
            await processItem(item)
        }
        
        // Save changes
        try context.save()
        
        // Update timestamp
        lastProcessedAt = Date()
    }
    
    // Private processing method
    private func processItem(_ item: SomeModel) async {
        // Heavy work here
        item.processedAt = Date()
        item.needsProcessing = false
    }
}

// Called from MainActor:
Task {
    try? await MyBackgroundProcessor.shared.process()
}
```

### ❌ ANTI-PATTERNS

```swift
// ❌ DON'T: Share ModelContext
let sharedContext = SAMModelContainer.newContext()  // ❌ Shared!

actor BadProcessor {
    func process() async {
        try? sharedContext.save()  // ❌ Potential data race
    }
}

// ❌ DON'T: Access MainActor state without await
actor BadProcessor {
    func process(coordinator: MainActorCoordinator) {
        print(coordinator.state)  // ❌ Error: accessing MainActor from actor
    }
}

// ❌ DON'T: Create context repeatedly
actor BadProcessor {
    func process() async {
        let ctx = SAMModelContainer.newContext()  // ❌ Creating new context every time
        // work...
    }
}
```

---

## Recipe 3: Adding a New Observable Manager

**Use Case:** You need a manager that SwiftUI can observe for state changes.

### ✅ CORRECT Pattern

```swift
import Foundation
import Observation

@MainActor
@Observable
final class MyFeatureManager {
    
    // Singleton
    static let shared = MyFeatureManager()
    
    // Observable state (no @Published needed)
    private(set) var isActive: Bool = false
    private(set) var status: Status = .idle
    private(set) var items: [Item] = []
    
    // Derived properties
    var hasItems: Bool {
        !items.isEmpty
    }
    
    // Private init
    private init() {
        setupObservers()
    }
    
    // Public API
    func activate() {
        isActive = true
        status = .active
        loadItems()
    }
    
    func deactivate() {
        isActive = false
        status = .idle
        items = []
    }
    
    // Private methods
    private func loadItems() {
        Task {
            let ctx = SAMModelContainer.newContext()
            let descriptor = FetchDescriptor<Item>()
            items = (try? ctx.fetch(descriptor)) ?? []
        }
    }
    
    private func setupObservers() {
        Task {
            for await _ in NotificationCenter.default.notifications(named: .dataDidChange) {
                loadItems()
            }
        }
    }
}

// Used in SwiftUI:
struct MyView: View {
    @Environment(MyFeatureManager.self) private var manager
    
    var body: some View {
        List(manager.items) { item in
            Text(item.name)
        }
    }
}
```

### ❌ ANTI-PATTERNS

```swift
// ❌ DON'T: Use ObservableObject (Combine)
import Combine  // ❌ Avoid Combine

@MainActor
final class BadManager: ObservableObject {  // ❌ Old pattern
    @Published var state: State = .idle  // ❌ @Published is Combine
}

// ❌ DON'T: Missing MainActor
@Observable  // ❌ Missing @MainActor
final class BadManager {
    var state: State = .idle
}

// ❌ DON'T: @objc selectors
@MainActor
@Observable
final class BadManager {
    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleChange),  // ❌ Old pattern
            name: .dataDidChange,
            object: nil
        )
    }
    
    @objc private func handleChange() {  // ❌ @objc not needed
        loadData()
    }
}
```

---

## Recipe 4: Querying SwiftData

**Use Case:** You need to fetch models from SwiftData.

### ✅ CORRECT Pattern

```swift
// From MainActor:
@MainActor
func fetchActiveItems() throws -> [Item] {
    let ctx = SAMModelContainer.newContext()
    
    // Use predicate for filtering
    let predicate = #Predicate<Item> { item in
        item.isActive == true && item.deletedAt == nil
    }
    
    let descriptor = FetchDescriptor<Item>(
        predicate: predicate,
        sortBy: [
            SortDescriptor(\.priority, order: .reverse),
            SortDescriptor(\.createdAt, order: .forward)
        ]
    )
    
    return try ctx.fetch(descriptor)
}

// From Actor:
actor DataProcessor {
    private let context: ModelContext
    
    init() {
        self.context = SAMModelContainer.newContext()
    }
    
    func fetchActiveItems() throws -> [Item] {
        let predicate = #Predicate<Item> { item in
            item.isActive == true && item.deletedAt == nil
        }
        
        let descriptor = FetchDescriptor<Item>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        
        return try context.fetch(descriptor)
    }
}
```

### ❌ ANTI-PATTERNS

```swift
// ❌ DON'T: Filter in memory
func fetchActiveItems() throws -> [Item] {
    let ctx = SAMModelContainer.newContext()
    let all = try ctx.fetch(FetchDescriptor<Item>())
    return all.filter { $0.isActive }  // ❌ In-memory filter
}

// ❌ DON'T: Use RawRepresentable enums directly in predicates (can cause issues)
let predicate = #Predicate<Item> { $0.state == .active }  // ⚠️ May fail

// ✅ DO: Use raw value for RawRepresentable enums
let targetState = ItemState.active.rawValue
let predicate = #Predicate<Item> { $0.stateRawValue == targetState }  // ✅

// ❌ DON'T: Share context across actors
let sharedCtx = SAMModelContainer.newContext()  // ❌

@MainActor
func mainWork() {
    try? sharedCtx.save()  // ❌
}

actor Worker {
    func work() async {
        try? sharedCtx.save()  // ❌ Data race!
    }
}
```

---

## Recipe 5: Passing Data Between Actors

**Use Case:** You need to pass data from MainActor to a background actor.

### ✅ CORRECT Pattern: Pass IDs

```swift
// Step 1: Extract IDs on MainActor
@MainActor
func getItemsToProcess() throws -> [UUID] {
    let ctx = SAMModelContainer.newContext()
    let predicate = #Predicate<Item> { $0.needsProcessing == true }
    let descriptor = FetchDescriptor<Item>(predicate: predicate)
    let items = try ctx.fetch(descriptor)
    return items.map(\.id)  // ✅ Value types only
}

// Step 2: Process using IDs on actor
actor Processor {
    private let context: ModelContext
    
    init() {
        self.context = SAMModelContainer.newContext()
    }
    
    func process(itemIDs: [UUID]) async throws {
        for id in itemIDs {
            // Fetch on this actor's context
            let descriptor = FetchDescriptor<Item>(
                predicate: #Predicate { $0.id == id }
            )
            
            if let item = try context.fetch(descriptor).first {
                // Process item
                item.processedAt = Date()
                item.needsProcessing = false
            }
        }
        
        try context.save()
    }
}

// Usage:
@MainActor
func doWork() async throws {
    let ids = try getItemsToProcess()
    try await Processor().process(itemIDs: ids)
}
```

### ✅ CORRECT Pattern: Create DTO

```swift
// Define Sendable value type
struct ItemSummary: Sendable {
    let id: UUID
    let name: String
    let priority: Int
    let createdAt: Date
}

// Step 1: Extract DTOs on MainActor
@MainActor
func getItemSummaries() throws -> [ItemSummary] {
    let ctx = SAMModelContainer.newContext()
    let items = try ctx.fetch(FetchDescriptor<Item>())
    
    return items.map { item in
        ItemSummary(
            id: item.id,
            name: item.name,
            priority: item.priority,
            createdAt: item.createdAt
        )
    }
}

// Step 2: Process DTOs on actor
actor Reporter {
    func generateReport(_ summaries: [ItemSummary]) async {
        for summary in summaries {
            print("\(summary.name) (priority: \(summary.priority))")
        }
    }
}

// Usage:
@MainActor
func doWork() async throws {
    let summaries = try getItemSummaries()
    await Reporter().generateReport(summaries)
}
```

### ❌ ANTI-PATTERNS

```swift
// ❌ DON'T: Pass model objects
@MainActor
func getItems() throws -> [Item] {
    let ctx = SAMModelContainer.newContext()
    return try ctx.fetch(FetchDescriptor<Item>())
}

actor Processor {
    func process(items: [Item]) async {  // ❌ Item is @Model, not Sendable
        for item in items {
            item.process()  // ❌ ERROR: Accessing MainActor model from actor
        }
    }
}
```

---

## Recipe 6: Handling Notifications

**Use Case:** You need to react to system notifications.

### ✅ CORRECT Pattern: Async Sequences

```swift
@MainActor
final class MyCoordinator {
    
    init() {
        setupObservers()
    }
    
    private func setupObservers() {
        // Each notification gets its own Task
        Task {
            for await notification in NotificationCenter.default.notifications(named: .eventStoreChanged) {
                handleEventStoreChange(notification)
            }
        }
        
        Task {
            for await notification in NotificationCenter.default.notifications(named: .dataDidChange) {
                handleDataChange(notification)
            }
        }
    }
    
    private func handleEventStoreChange(_ notification: Notification) {
        // Handle on MainActor
        print("Event store changed")
    }
    
    private func handleDataChange(_ notification: Notification) {
        // Handle on MainActor
        print("Data changed")
    }
}
```

### ❌ ANTI-PATTERNS

```swift
// ❌ DON'T: Use @objc selectors
@MainActor
final class BadCoordinator {
    
    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleChange),  // ❌ Old pattern
            name: .dataDidChange,
            object: nil
        )
    }
    
    @objc private func handleChange() {  // ❌ Not needed in Swift 6
        print("Changed")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)  // ❌ Manual cleanup
    }
}

// ❌ DON'T: Redundant Task wrapping
@MainActor
final class BadCoordinator {
    private func handleChange() {
        Task { @MainActor in  // ❌ Redundant - already @MainActor
            doWork()
        }
    }
}
```

---

## Recipe 7: Debouncing Work

**Use Case:** You want to debounce rapid triggers (e.g., search as you type, burst imports).

### ✅ CORRECT Pattern: Actor with Task Cancellation

```swift
actor DebouncedWorker {
    
    static let shared = DebouncedWorker()
    
    private var runningTask: Task<Void, Never>?
    private let debounceInterval: Duration = .seconds(1.0)
    
    func run(work: @Sendable @escaping () async -> Void) {
        // Cancel existing task
        runningTask?.cancel()
        
        // Start new debounced task
        runningTask = Task {
            try? await Task.sleep(for: debounceInterval)
            
            guard !Task.isCancelled else { return }
            
            await work()
        }
    }
}

// Usage from MainActor:
@MainActor
final class SearchCoordinator {
    func searchTextDidChange(_ text: String) {
        Task {
            await DebouncedWorker.shared.run {
                await self.performSearch(text)
            }
        }
    }
    
    private func performSearch(_ text: String) async {
        // Actual search logic
        print("Searching for: \(text)")
    }
}
```

### Alternative: Inline Debouncing

```swift
@MainActor
final class SearchCoordinator {
    private var searchTask: Task<Void, Never>?
    
    func searchTextDidChange(_ text: String) {
        searchTask?.cancel()
        
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            
            guard !Task.isCancelled else { return }
            
            await performSearch(text)
        }
    }
    
    private func performSearch(_ text: String) async {
        print("Searching for: \(text)")
    }
}
```

---

## Recipe 8: Task Groups for Parallel Work

**Use Case:** You need to process multiple items in parallel.

### ✅ CORRECT Pattern

```swift
nonisolated func processContacts(_ identifiers: [String]) async -> [ContactData] {
    await withTaskGroup(of: ContactData?.self) { group in
        // Add tasks for each identifier
        for id in identifiers {
            group.addTask(priority: .utility) {
                await self.resolveContact(id)
            }
        }
        
        // Collect results
        var results: [ContactData] = []
        for await result in group {
            if let result {
                results.append(result)
            }
        }
        return results
    }
}

nonisolated private func resolveContact(_ identifier: String) async -> ContactData? {
    // Potentially slow I/O
    guard let contact = try? contactStore.unifiedContact(
        withIdentifier: identifier,
        keysToFetch: keys
    ) else {
        return nil
    }
    
    return ContactData(from: contact)
}
```

### Pattern: Maintain Order

```swift
nonisolated func processInOrder(_ identifiers: [String]) async -> [ContactData] {
    await withTaskGroup(of: (Int, ContactData?).self) { group in
        // Add tasks with index
        for (index, id) in identifiers.enumerated() {
            group.addTask(priority: .utility) {
                let data = await self.resolveContact(id)
                return (index, data)
            }
        }
        
        // Collect and sort by index
        var indexed: [(Int, ContactData?)] = []
        for await result in group {
            indexed.append(result)
        }
        
        return indexed
            .sorted { $0.0 < $1.0 }
            .compactMap { $0.1 }
    }
}
```

---

## Recipe 9: Heavy CPU-Bound Work

**Use Case:** You have expensive CPU work that should always run on background threads.

### ✅ CORRECT Pattern: @concurrent

```swift
nonisolated struct ImageProcessor {
    
    @concurrent
    func process(data: Data) async -> ProcessedImage? {
        // This ALWAYS runs on concurrent thread pool
        // Heavy CPU work here
        guard let image = decodeImage(data) else { return nil }
        let processed = applyFilters(image)
        return ProcessedImage(processed)
    }
    
    private func decodeImage(_ data: Data) -> RawImage? {
        // CPU-intensive decoding
        ...
    }
    
    private func applyFilters(_ image: RawImage) -> RawImage {
        // CPU-intensive processing
        ...
    }
}

// Called from MainActor:
@MainActor
func processImage(_ data: Data) async {
    let processed = await ImageProcessor().process(data: data)
    self.displayedImage = processed
}
```

### Alternative: Explicit Actor

```swift
actor CPUProcessor {
    func processLargeDataset(_ data: [DataPoint]) async -> [Result] {
        // Runs on this actor (off MainActor)
        return data.map { processPoint($0) }
    }
    
    private func processPoint(_ point: DataPoint) -> Result {
        // CPU-intensive calculation
        ...
    }
}
```

---

## Recipe 10: Updating Models from Background

**Use Case:** Background actor needs to update SwiftData models.

### ✅ CORRECT Pattern

```swift
actor BackgroundUpdater {
    private let context: ModelContext
    
    init() {
        self.context = SAMModelContainer.newContext()
    }
    
    func updateItems(_ itemIDs: [UUID]) async throws {
        for id in itemIDs {
            // Fetch on this actor's context
            let descriptor = FetchDescriptor<Item>(
                predicate: #Predicate { $0.id == id }
            )
            
            guard let item = try context.fetch(descriptor).first else {
                continue
            }
            
            // Update item
            item.updatedAt = Date()
            item.status = .processed
        }
        
        // Save all changes
        try context.save()
    }
}

// Called from MainActor:
@MainActor
func processItems(_ ids: [UUID]) async {
    do {
        try await BackgroundUpdater().updateItems(ids)
        
        // After background update, refresh UI if needed
        refreshUI()
    } catch {
        print("Update failed: \(error)")
    }
}
```

### ❌ ANTI-PATTERNS

```swift
// ❌ DON'T: Update models fetched on different actor
@MainActor
func getItems() -> [Item] {
    let ctx = SAMModelContainer.newContext()
    return (try? ctx.fetch(FetchDescriptor<Item>())) ?? []
}

actor BadUpdater {
    func update(_ items: [Item]) async {  // ❌ Items from MainActor
        for item in items {
            item.status = .processed  // ❌ ERROR
        }
    }
}
```

---

## Summary

### Quick Decision Tree

```
Need to add code?
│
├─ UI-facing?
│  └─ YES → @MainActor class + nonisolated singletons
│
├─ Heavy processing?
│  └─ YES → actor with own ModelContext
│
├─ SwiftUI observable?
│  └─ YES → @MainActor @Observable class
│
├─ Pass data between actors?
│  └─ YES → Pass UUIDs or Sendable DTOs
│
└─ System notifications?
   └─ YES → async sequence in Task
```

---

**End of Cookbook**

*For more details, see [CONCURRENCY_ARCHITECTURE_GUIDE.md](CONCURRENCY_ARCHITECTURE_GUIDE.md)*
