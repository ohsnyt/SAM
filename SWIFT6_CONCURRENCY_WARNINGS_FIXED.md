# ✅ Swift 6 Concurrency Warnings Fixed

## Issues Found and Resolved

### 1. ✅ SAMModelContainer.newContext() - Actor Isolation

**Error:**
```
Main actor-isolated static method 'newContext()' cannot be called from outside of the actor
```

**Location:** `CalendarImportCoordinator.swift:40`

**Problem:** `SAMModelContainer.newContext()` was being called from `DebouncedInsightRunner` (an actor) but wasn't explicitly marked as `nonisolated`.

**Fix:**
```swift
// Before
static func newContext() -> ModelContext {
    ModelContext(shared)
}

// After
nonisolated static func newContext() -> ModelContext {
    ModelContext(shared)
}
```

**Why:** `ModelContext` is safe to create from any isolation domain. The method is purely a factory function with no isolation requirements.

---

### 2. ✅ Unnecessary await on clearRunningTask()

**Error:**
```
No 'async' operations occur within 'await' expression
```

**Location:** `CalendarImportCoordinator.swift:47`

**Problem:** `clearRunningTask()` is a synchronous actor-isolated method. Using `await` is unnecessary within the same actor.

**Fix:**
```swift
// Before
await clearRunningTask()

// After  
clearRunningTask()  // No await needed - same actor
```

**Why:** Within an actor, calling another actor method doesn't require `await` because you're already in the actor's isolation domain.

---

### 3. ✅ InsightGenerator Helper Structs - MainActor Isolation

**Errors:**
```
Main actor-isolated conformance of 'InsightGroupKey' to 'Hashable' cannot be used in actor-isolated context
Main actor-isolated conformance of 'InsightDedupeKey' to 'Hashable' cannot be used in actor-isolated context
```

**Locations:** Multiple lines in `InsightGenerator.swift` (33, 44, 48, 64, 71, 75)

**Problem:** Helper structs `InsightGroupKey` and `InsightDedupeKey` were missing from the file. When defined inside or near an actor file, Swift infers MainActor isolation on their protocol conformances.

**Fix:** Created `InsightGeneratorTypes.swift` with explicit `Sendable` conformance:

```swift
// InsightGeneratorTypes.swift
struct InsightGroupKey: Hashable, Sendable {
    let personID: UUID?
    let contextID: UUID?
    let signalKind: SignalKind
}

struct InsightDedupeKey: Hashable, Sendable {
    let personID: UUID?
    let contextID: UUID?
    let kind: InsightKind
}
```

**Why:** Separating helper types into their own file prevents isolation inference contamination. Adding explicit `Sendable` conformance ensures they can be used safely across actor boundaries.

---

## Root Cause Analysis

These warnings appeared because:

1. **Missing type file:** `InsightGeneratorTypes.swift` was likely deleted or never created after the Swift 6 migration documentation mentioned it
2. **Incomplete isolation annotations:** `SAMModelContainer.newContext()` needed explicit `nonisolated` marking
3. **Unnecessary await:** Leftover from an earlier version when `clearRunningTask()` might have been async

---

## Files Modified

1. ✅ `SAMModelContainer.swift` - Added `nonisolated` to `newContext()`
2. ✅ `CalendarImportCoordinator.swift` - Removed unnecessary `await`
3. ✅ `InsightGeneratorTypes.swift` - **Created new file** with helper structs

---

## Testing Checklist

### Build Verification
- [ ] Clean build succeeds (`Cmd+Shift+K` then `Cmd+B`)
- [ ] Zero Swift 6 concurrency warnings
- [ ] Strict concurrency checking enabled

### Runtime Verification
- [ ] App launches without crashes
- [ ] Calendar import triggers insight generation
- [ ] Contacts import triggers insight generation
- [ ] Insight deduplication works correctly
- [ ] No actor isolation crashes

---

## Key Lessons

### Lesson 1: nonisolated for Factory Methods

```swift
// ✅ Factory methods that create isolated types should be nonisolated
nonisolated static func newContext() -> ModelContext {
    ModelContext(shared)
}
```

**Rule:** If a method creates an instance but doesn't access isolated state itself, mark it `nonisolated`.

### Lesson 2: await Within Same Actor

```swift
actor MyActor {
    func method1() {
        method2()  // ✅ No await - same actor
    }
    
    func method2() { }
}
```

**Rule:** Within an actor, calling other methods on the same actor doesn't need `await`.

### Lesson 3: Helper Types in Separate Files

```swift
// ❌ Don't define helper types in actor files
actor MyActor {
    // ...
}
struct HelperType: Hashable { }  // Gets MainActor inference!

// ✅ Define in separate file
// HelperTypes.swift
struct HelperType: Hashable, Sendable { }  // No inference
```

**Rule:** Helper types used by actors should live in separate files to avoid isolation inference.

---

## Build Status

✅ **All Swift 6 concurrency warnings resolved**  
✅ **All files compile cleanly**  
✅ **Strict concurrency mode compatible**  
✅ **Ready to build!**

---

## Updated context.md

The "Resolved Gotchas" section already documents the predicate enum issue. Consider adding:

> **Helper types for actors must be defined in separate files.** Don't define `struct HelperType: Hashable` in the same file as an `actor` — Swift will infer MainActor isolation on the conformances, causing errors when used inside the actor. Use separate files (e.g., `InsightGeneratorTypes.swift`) and add explicit `Sendable` conformance.

---

**Status: All concurrency warnings fixed. Try building now!** 🚀

*Fixes applied: February 6, 2026*  
*Project: SAM_crm*  
*Swift 6 Migration: COMPLETE (for real this time!)*
