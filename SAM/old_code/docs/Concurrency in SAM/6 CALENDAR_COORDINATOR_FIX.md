# CalendarImportCoordinator Concurrency Fix

## Problem

The `CalendarImportCoordinator` class was experiencing Swift 6 concurrency errors:

```
error: Passing closure as a 'sending' parameter risks causing data races between 
main actor-isolated code and concurrent execution of the closure
```

## Root Cause

The coordinator is marked `@MainActor`, which means all its stored properties are also MainActor-isolated by default:

```swift
@MainActor
final class CalendarImportCoordinator {
    private let evidenceStore = EvidenceRepository.shared  // MainActor-isolated
    private let permissions = PermissionsManager.shared    // MainActor-isolated
    
    func kick(reason: String) {
        Task {
            // ❌ Capturing MainActor-isolated properties in a closure
            await importIfNeeded(reason: reason)
        }
    }
}
```

When creating a `Task` inside a `@MainActor` function, the closure captures `self`, which includes all MainActor-isolated properties. This creates a potential data race because:

1. The Task could potentially run on any actor
2. It's trying to access MainActor-isolated properties from a non-MainActor context
3. Swift 6's strict concurrency checking catches this as unsafe

## Solution

Mark the stored property references as `nonisolated` and explicitly mark the Task closure with `@MainActor in`:

```swift
@MainActor
final class CalendarImportCoordinator {
    // ✅ nonisolated: These are immutable references to singletons
    nonisolated private let evidenceStore = EvidenceRepository.shared
    nonisolated private let permissions = PermissionsManager.shared
    
    // ✅ nonisolated: Immutable TimeInterval constants
    nonisolated private let minimumIntervalNormal: TimeInterval = 300
    nonisolated private let minimumIntervalChanged: TimeInterval = 10
    
    func kick(reason: String) {
        debounceTask?.cancel()
        
        // ✅ Explicit MainActor annotation
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            await self.importIfNeeded(reason: reason)
        }
    }
}
```

## Why This Works

### `nonisolated` for Singleton References

```swift
nonisolated private let evidenceStore = EvidenceRepository.shared
```

This is safe because:
- `EvidenceRepository.shared` is a **constant reference** (let, not var)
- The reference itself never changes
- The repository manages its own isolation internally
- Multiple actors can safely hold the same immutable reference

### `@MainActor in` for Task Closures

```swift
Task { @MainActor in
    await self.importIfNeeded(reason: reason)
}
```

This explicitly tells Swift:
- The closure will run on the MainActor
- Accessing MainActor-isolated properties is safe
- The Task inherits the MainActor context properly

## General Pattern

**When you see:** "Passing closure as a 'sending' parameter risks causing data races"

**In a `@MainActor` class capturing properties in `Task` closures:**

### Step 1: Identify captured properties
Look for what the Task closure is accessing:
- Stored properties
- Methods on self
- Other MainActor-isolated state

### Step 2: Decide on strategy

#### Strategy A: Make properties `nonisolated` (Preferred for singletons)
```swift
@MainActor
final class Coordinator {
    nonisolated private let repository = Repository.shared  // ✅
    
    func work() {
        Task { @MainActor in
            await repository.method()
        }
    }
}
```

**Use when:**
- Property is a constant reference (`let`)
- Property is a singleton or shared instance
- Property manages its own concurrency internally

#### Strategy B: Make the method async
```swift
@MainActor
final class Coordinator {
    private let repository = Repository.shared
    
    func work() async {  // ✅ Made async
        await repository.method()  // Direct call, no Task needed
    }
}
```

**Use when:**
- The caller can be async
- You don't need fire-and-forget semantics
- You want to await the result

#### Strategy C: Copy to local variable
```swift
@MainActor
final class Coordinator {
    private let repository = Repository.shared
    
    func work() {
        let repo = repository  // ✅ Local copy
        Task {
            await repo.method()
        }
    }
}
```

**Use when:**
- You can't make the property nonisolated
- You can't make the method async
- Property is a constant reference

## Applied to CalendarImportCoordinator

### Properties Made `nonisolated`

```swift
// ✅ Singletons - safe to be nonisolated
nonisolated private let evidenceStore = EvidenceRepository.shared
nonisolated private let permissions = PermissionsManager.shared

// ✅ Constants - immutable values
nonisolated private let minimumIntervalNormal: TimeInterval = 300
nonisolated private let minimumIntervalChanged: TimeInterval = 10
```

### Properties Kept MainActor-Isolated

```swift
// ⚠️ Remain MainActor-isolated because they're mutable or @AppStorage
@AppStorage("sam.calendar.import.enabled") private var importEnabled: Bool = true
@AppStorage("sam.calendar.selectedCalendarID") private var selectedCalendarID: String = ""
private var debounceTask: Task<Void, Never>?
```

### Task Closures Marked Explicitly

```swift
func kick(reason: String) {
    debounceTask?.cancel()
    
    // ✅ Explicit @MainActor in
    debounceTask = Task { @MainActor in
        try? await Task.sleep(for: .seconds(1.5))
        await self.importIfNeeded(reason: reason)
    }
}
```

## Benefits of This Approach

1. **Minimal changes** - Only marked properties that are safe to be nonisolated
2. **Clear intent** - Explicit `@MainActor in` shows the Task runs on MainActor
3. **Type-safe** - Compiler enforces correct usage
4. **Maintainable** - Pattern is easy to understand and replicate

## When to Apply This Pattern

Apply this pattern whenever you have:

✅ A `@MainActor` class  
✅ Creating `Task` closures  
✅ Accessing stored properties inside those closures  
✅ Getting "sending parameter" errors  

## Related Files

This same pattern should be applied to:
- `ContactsImportCoordinator` (if it exists)
- Any other `@MainActor` coordinator that creates Tasks
- Any `@MainActor` class that delegates work asynchronously

## Testing

After applying this fix:

1. ✅ Build succeeds with no warnings
2. ✅ Strict concurrency checking enabled
3. ✅ No runtime warnings about actor isolation
4. ✅ Calendar import continues to work correctly

## References

- Full concurrency guide: `CONCURRENCY_ARCHITECTURE_GUIDE.md`
- Quick reference: `CONCURRENCY_QUICK_REFERENCE.md`
- Data model guide: `DATA_MODEL_ARCHITECTURE.md`

---

**Date Fixed:** February 9, 2026  
**Swift Version:** Swift 6.0+  
**Status:** ✅ Resolved
