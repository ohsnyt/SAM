# Swift 6 Concurrency Quick Reference

## 🎯 Core Patterns Used in This Codebase

### ✅ DO: Actor for Background Work
```swift
actor BackgroundWorker {
    private var state: State
    
    func doWork() async {
        // Heavy processing
    }
}

// Call from MainActor:
Task {
    await BackgroundWorker.shared.doWork()
}
```

### ✅ DO: @MainActor for UI Code
```swift
@MainActor
@Observable
final class ViewModel {
    private(set) var state: State
    
    func updateUI() {
        // Direct call - already on MainActor
        state = .updated
    }
}
```

### ✅ DO: Task-Based Debouncing
```swift
@MainActor
final class Coordinator {
    private var debounceTask: Task<Void, Never>?
    
    func kick() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            await doWork()
        }
    }
}
```

### ✅ DO: Async Notification Sequences
```swift
private func setupObservers() {
    Task {
        for await notification in NotificationCenter.default.notifications(named: .someEvent) {
            handleEvent(notification)
        }
    }
}
```

### ✅ DO: Database Predicates
```swift
func fetchActive() throws -> [Item] {
    let predicate = #Predicate<Item> { $0.state == .active }
    let descriptor = FetchDescriptor<Item>(
        predicate: predicate,
        sortBy: [SortDescriptor(\.date, order: .reverse)]
    )
    return try context.fetch(descriptor)
}
```

### ✅ DO: Task Groups with Priority
```swift
await withTaskGroup(of: Result?.self) { group in
    for item in items {
        group.addTask(priority: .utility) {
            await process(item)
        }
    }
    for await result in group {
        // Handle result
    }
}
```

---

## ❌ DON'T: Swift 5 Anti-Patterns

### ❌ NO: Manual Locks
```swift
// ❌ DON'T
private let lock = NSLock()
private let lock = OSAllocatedUnfairLock(initialState: false)

// ✅ DO
actor MyActor {
    private var state: State  // Automatically synchronized
}
```

### ❌ NO: Task.detached (Usually)
```swift
// ❌ DON'T
Task.detached {
    // Breaks structured concurrency
}

// ✅ DO
Task {
    // Structured concurrency
}
```

### ❌ NO: ObservableObject + @Published
```swift
// ❌ DON'T (Swift 5 + Combine)
import Combine

final class Manager: ObservableObject {
    @Published var state: State
}

// ✅ DO (Swift 6 + Observation)
@Observable
final class Manager {
    var state: State  // Automatically observed
}
```

### ❌ NO: @objc Notification Selectors
```swift
// ❌ DON'T
NotificationCenter.default.addObserver(
    self,
    selector: #selector(handleEvent),
    name: .someEvent,
    object: nil
)

@objc func handleEvent() { }

// ✅ DO
Task {
    for await _ in NotificationCenter.default.notifications(named: .someEvent) {
        handleEvent()
    }
}
```

### ❌ NO: In-Memory Filtering
```swift
// ❌ DON'T
let all = try context.fetch(FetchDescriptor<Item>())
return all.filter { $0.state == .active }

// ✅ DO
let predicate = #Predicate<Item> { $0.state == .active }
let descriptor = FetchDescriptor<Item>(predicate: predicate)
return try context.fetch(descriptor)
```

### ❌ NO: Nanoseconds Literals
```swift
// ❌ DON'T
try await Task.sleep(nanoseconds: 1_500_000_000)

// ✅ DO
try await Task.sleep(for: .seconds(1.5))
```

### ❌ NO: Completion Handlers
```swift
// ❌ DON'T
func doWork(completion: @escaping (Result) -> Void) {
    // ...
}

// ✅ DO
func doWork() async throws -> Result {
    // ...
}
```

### ❌ NO: DispatchQueue
```swift
// ❌ DON'T
DispatchQueue.global().async {
    // Work
    DispatchQueue.main.async {
        // Update UI
    }
}

// ✅ DO
Task {
    let result = await backgroundWork()
    await MainActor.run {
        updateUI(result)
    }
}
```

---

## 🎓 Decision Tree

### "Should I use an actor?"

```
Is this a class with mutable state?
│
├─ YES → Will it be accessed from multiple actors?
│        │
│        ├─ YES → Is it UI-facing (SwiftUI)?
│        │        │
│        │        ├─ YES → Use @MainActor
│        │        │
│        │        └─ NO → Use actor
│        │
│        └─ NO → Is it UI-facing?
│                 │
│                 ├─ YES → Use @MainActor
│                 │
│                 └─ NO → Use actor (for future safety)
│
└─ NO → Is it a stateless utility?
         │
         ├─ YES → Use enum or struct
         │
         └─ NO → Reconsider design
```

### "Should I use @MainActor?"

```
Does this code update UI?
│
├─ YES → Use @MainActor
│
└─ NO → Does it integrate with SwiftUI (@Observable, @Query)?
         │
         ├─ YES → Use @MainActor
         │
         └─ NO → Use actor or nonisolated
```

### "Should I use Task or Task.detached?"

```
Do I need to inherit task priority/locals?
│
├─ YES → Use Task { }
│
└─ NO → Am I implementing fire-and-forget?
         │
         ├─ YES → Use Task { } (still prefer structured)
         │
         └─ NO → Reconsider design
```

**Rule of thumb:** Use `Task { }` 99% of the time. Only use `Task.detached` if you have a specific reason to break structured concurrency.

---

## 🔍 Common Errors and Fixes

### Error: "Actor-isolated instance method cannot be called from outside of the actor"

```swift
// ❌ Problem
actor MyActor {
    func doWork() { }
}

// From MainActor:
MyActor.shared.doWork()  // ❌ Missing await

// ✅ Solution
Task {
    await MyActor.shared.doWork()
}
```

### Error: "Call to main actor-isolated instance method in synchronous nonisolated context"

```swift
// ❌ Problem
@MainActor
final class Manager {
    func updateUI() { }
}

// From actor:
Manager.shared.updateUI()  // ❌ Missing await

// ✅ Solution
await Manager.shared.updateUI()
```

### Error: "Expression is 'async' but is not marked with 'await'"

```swift
// ❌ Problem
let result = doAsyncWork()

// ✅ Solution
let result = await doAsyncWork()
```

### Warning: "Converting function value of type '@MainActor (X) -> Y' to '(X) -> Y' loses global actor"

```swift
// ❌ Problem
let closure = someMainActorMethod

// ✅ Solution 1: Keep MainActor isolation
let closure: @MainActor (X) -> Y = someMainActorMethod

// ✅ Solution 2: Make the method nonisolated if appropriate
nonisolated func someMethod() { }
```

---

## 📊 Performance Tips

### ✅ Use Task Groups for Parallelism
```swift
// Process items in parallel
await withTaskGroup(of: Result.self) { group in
    for item in items {
        group.addTask {
            await process(item)
        }
    }
}
```

### ✅ Set Appropriate Priority
```swift
// Low-priority background work
group.addTask(priority: .utility) {
    await heavyWork()
}

// High-priority user-initiated work
group.addTask(priority: .userInitiated) {
    await urgentWork()
}
```

### ✅ Use Database Predicates
```swift
// Push filtering to database layer
let predicate = #Predicate<Item> {
    $0.isActive && $0.date > cutoffDate
}
```

### ✅ Avoid Blocking MainActor
```swift
// ❌ DON'T: Heavy work on MainActor
@MainActor
func processHeavyData() {
    // Blocks UI
}

// ✅ DO: Move to background actor
actor DataProcessor {
    func processHeavyData() {
        // Doesn't block UI
    }
}
```

---

## 🧪 Testing Patterns

### Testing Actors
```swift
@Test
func testActorBehavior() async {
    let actor = MyActor()
    
    // Use await for actor calls
    await actor.doWork()
    
    let result = await actor.getResult()
    #expect(result == expectedValue)
}
```

### Testing MainActor Code
```swift
@Test
@MainActor
func testMainActorCode() async {
    let coordinator = CalendarImportCoordinator.shared
    
    // Direct call - already on MainActor
    coordinator.kick(reason: "test")
    
    // Wait for async work
    try? await Task.sleep(for: .seconds(0.1))
    
    #expect(coordinator.someState == .expected)
}
```

### Testing Async Sequences
```swift
@Test
func testNotifications() async throws {
    let expectation = Expectation()
    
    Task {
        for await notification in NotificationCenter.default.notifications(named: .test) {
            expectation.fulfill()
            break
        }
    }
    
    NotificationCenter.default.post(name: .test, object: nil)
    
    await expectation.fulfillment
}
```

---

## 📚 Further Reading

### Official Documentation
- [Swift Concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency)
- [Observation Framework](https://developer.apple.com/documentation/observation)
- [Swift 6 Migration Guide](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/)

### Key WWDC Sessions
- WWDC 2023: Session 10149 - "Discover Observation in SwiftUI"
- WWDC 2022: Session 110350 - "Eliminate Data Races Using Swift Concurrency"
- WWDC 2021: Session 10132 - "Meet async/await in Swift"
- WWDC 2021: Session 10133 - "Protect mutable state with Swift actors"

### Community Resources
- [Swift Forums: Concurrency](https://forums.swift.org/c/development/concurrency)
- [Swift Evolution Proposals](https://github.com/apple/swift-evolution)

---

## ✅ Review Checklist

Before committing code, verify:

- [ ] No manual locks (`NSLock`, `OSAllocatedUnfairLock`, etc.)
- [ ] No `Task.detached` without justification
- [ ] No Combine imports (use `@Observable`)
- [ ] No `@objc` notification observers
- [ ] All actor calls use `await`
- [ ] Database queries use predicates
- [ ] Task priorities are appropriate
- [ ] No blocking work on MainActor
- [ ] Strict concurrency checking enabled
- [ ] Zero concurrency warnings

---

**Quick Tip:** When in doubt, use an actor. It's easier to remove isolation later than to add it after data races appear.

*Last updated: February 6, 2026*  
*Project: SAM_crm*
