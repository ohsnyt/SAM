# Swift 6 Concurrency Quick Reference - SAM CRM

## Common Errors & Solutions

### Error: "Passing closure as a 'sending' parameter risks causing data races"

**When you see this:**
```swift
@MainActor
final class MyCoordinator {
    private let repository = SomeRepository.shared  // MainActor-isolated
    
    func doWork() {
        Task {
            // ❌ ERROR: Capturing 'self.repository' in closure
            await repository.someMethod()
        }
    }
}
```

**Quick Fix Options:**

**Option 1: Make property `nonisolated`** (Preferred)
```swift
@MainActor
final class MyCoordinator {
    nonisolated private let repository = SomeRepository.shared  // ✅
    
    func doWork() {
        Task { @MainActor in  // Explicit MainActor
            await repository.someMethod()
        }
    }
}
```

**Option 2: Make method `async`**
```swift
@MainActor
final class MyCoordinator {
    private let repository = SomeRepository.shared
    
    func doWork() async {  // ✅ Made async
        await repository.someMethod()  // ✅ Direct call
    }
}
```

**Option 3: Copy reference before Task**
```swift
@MainActor
final class MyCoordinator {
    private let repository = SomeRepository.shared
    
    func doWork() {
        let repo = repository  // ✅ Copy to local
        Task {
            await repo.someMethod()
        }
    }
}
```

---

## Cheat Sheet

### When to use what

| Scenario | Solution |
|----------|----------|
| UI coordinator class | `@MainActor final class` |
| Background processing | `actor` |
| SwiftUI observable state | `@MainActor @Observable final class` |
| Shared singletons | `nonisolated static let shared` |
| Heavy CPU work | `@concurrent func` |
| Fire-and-forget background | `Task { await actor.method() }` |
| Notification observing | Async sequence in `Task` |

### Quick Patterns

#### Pattern: MainActor Coordinator
```swift
@MainActor
final class SomeCoordinator {
    static let shared = SomeCoordinator()
    
    // Make references nonisolated to avoid capture issues
    nonisolated private let repository = SomeRepository.shared
    
    func triggerWork() {
        Task { @MainActor in
            await repository.doWork()
        }
    }
}
```

#### Pattern: Background Actor
```swift
actor Worker {
    private let context: ModelContext
    
    init() {
        self.context = SAMModelContainer.newContext()
    }
    
    func doWork() async throws {
        let items = try context.fetch(FetchDescriptor<SomeModel>())
        // Process...
        try context.save()
    }
}
```

#### Pattern: Observable Manager
```swift
@MainActor
@Observable
final class Manager {
    static let shared = Manager()
    
    private(set) var status: Status
    
    private func setupObservers() {
        Task {
            for await notification in NotificationCenter.default.notifications(named: .someEvent) {
                handleEvent()
            }
        }
    }
}
```

#### Pattern: Pass IDs Between Actors
```swift
@MainActor
func getIDs() throws -> [UUID] {
    let ctx = SAMModelContainer.newContext()
    let items = try ctx.fetch(FetchDescriptor<SomeModel>())
    return items.map(\.id)  // ✅ Value types only
}

actor Worker {
    private let context: ModelContext
    
    init() {
        self.context = SAMModelContainer.newContext()
    }
    
    func process(ids: [UUID]) async throws {
        for id in ids {
            let descriptor = FetchDescriptor<SomeModel>(
                predicate: #Predicate { $0.id == id }
            )
            if let item = try context.fetch(descriptor).first {
                // Process on this actor's context
            }
        }
    }
}
```

---

## SwiftData Rules

### ✅ DO:
- Create one `ModelContext` per actor
- Use `SAMModelContainer.newContext()` for new contexts
- Pass UUIDs between actors, not model objects
- Use `#Predicate` for database-level filtering

### ❌ DON'T:
- Share a `ModelContext` across actors
- Pass `@Model` objects between actors
- Filter in memory (use predicates instead)
- Access models fetched on another actor

---

## Common Fixes

### Fix: Captured properties in Task
```swift
// Before
private let repo = Repository.shared
func work() {
    Task { await repo.method() }  // ❌ Capture error
}

// After
nonisolated private let repo = Repository.shared
func work() {
    Task { @MainActor in await repo.method() }  // ✅
}
```

### Fix: Accessing MainActor property from actor
```swift
// Before
actor Worker {
    func work(manager: MainActorManager) {
        print(manager.state)  // ❌ Error
    }
}

// After
actor Worker {
    func work(manager: MainActorManager) async {
        let state = await MainActor.run { manager.state }  // ✅
        print(state)
    }
}
```

### Fix: Non-Sendable type in Task
```swift
// Before
final class MyClass {
    var value: Int = 0
    func work() {
        Task { value += 1 }  // ❌ Not Sendable
    }
}

// After
@MainActor
final class MyClass {
    var value: Int = 0
    func work() {
        Task { value += 1 }  // ✅ All on MainActor
    }
}
```

---

## Testing Checklist

When you see a concurrency error:

1. ✅ Is the class `@MainActor` or `actor`?
2. ✅ Are captured properties `nonisolated`?
3. ✅ Is the Task explicitly marked with `@MainActor in` if needed?
4. ✅ Are you passing model objects between actors? (Use IDs instead)
5. ✅ Are you sharing a ModelContext? (Create per-actor)
6. ✅ Are you filtering in memory? (Use predicates)

---

## Resources

- Full guide: `CONCURRENCY_ARCHITECTURE_GUIDE.md`
- Data models: `DATA_MODEL_ARCHITECTURE.md`
- Migration status: `SWIFT6_MIGRATION_COMPLETE.md`

---

**Quick Tip:** When in doubt, make it `nonisolated` if it's a constant reference to a singleton!
