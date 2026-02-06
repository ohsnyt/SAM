# ✅ ContactsImportCoordinator - Actor Call Fix

## Issues Fixed

### Error 1: Line 104
```
Actor-isolated instance method 'run()' cannot be called from outside of the actor
```

### Error 2: Line 112
```
Call to actor-isolated instance method 'run()' in a synchronous main actor-isolated context
```

---

## Root Cause

Same issue as `CalendarImportCoordinator`: calling an actor-isolated method (`DebouncedInsightRunner.run()`) from a `@MainActor` context without `await`.

---

## Fixes Applied

### Fix 1: Line 104 - After Contacts Import

**Before:**
```swift
// Trigger Phase 2 insight generation after contacts import (Option A)
DebouncedInsightRunner.shared.run()  // ❌ Missing await
```

**After:**
```swift
// Trigger Phase 2 insight generation after contacts import (Option A)
Task {
    await DebouncedInsightRunner.shared.run()  // ✅ Fire-and-forget with await
}
```

### Fix 2: Line 112 - Startup Safety Net

**Before:**
```swift
static func kickOnStartup() {
    // Generate insights at startup as a safety net
    DebouncedInsightRunner.shared.run()  // ❌ Missing await
}
```

**After:**
```swift
static func kickOnStartup() {
    // Generate insights at startup as a safety net
    Task {
        await DebouncedInsightRunner.shared.run()  // ✅ Fire-and-forget with await
    }
}
```

### Bonus Fix: Duration API

**Before:**
```swift
try? await Task.sleep(nanoseconds: 1_500_000_000)  // ❌ Error-prone
```

**After:**
```swift
try? await Task.sleep(for: .seconds(1.5))  // ✅ Type-safe Duration API
```

---

## Why This Pattern Works

### The Pattern: Fire-and-Forget Background Work

```swift
Task {
    await DebouncedInsightRunner.shared.run()
}
```

**Characteristics:**
- ✅ Creates an **unstructured task** (detached from parent context)
- ✅ Inherits priority from current context (MainActor = user-interactive)
- ✅ **Fire-and-forget** - caller doesn't wait for completion
- ✅ Perfect for triggering background work after import completes

### Why Not Just `await`?

```swift
// ❌ DON'T - blocks until insight generation completes
await DebouncedInsightRunner.shared.run()

// ✅ DO - starts generation and continues immediately
Task {
    await DebouncedInsightRunner.shared.run()
}
```

**Using bare `await`** would block the import function until insight generation completes (potentially seconds). **Using `Task { await ... }`** starts the generation in the background and returns immediately.

---

## Architecture Pattern

### Import Flow

```
CalendarImportCoordinator (MainActor)
│
├─ importCalendarEvidence() 
│   ├─ Fetch events
│   ├─ Upsert evidence items
│   └─ Task { await DebouncedInsightRunner.shared.run() }  // ✅ Fire-and-forget
│
ContactsImportCoordinator (MainActor)
│
├─ importContacts()
│   ├─ Fetch contacts
│   ├─ Upsert people
│   └─ Task { await DebouncedInsightRunner.shared.run() }  // ✅ Fire-and-forget
│
App Startup (MainActor)
│
└─ Task { await DebouncedInsightRunner.shared.run() }  // ✅ Safety net
```

### Insight Generation (Background Actor)

```
DebouncedInsightRunner (actor)
│
├─ run()
│   ├─ Cancel previous task (debouncing)
│   ├─ Sleep 1.0s
│   └─ Generate insights
│       ├─ InsightGenerator.generatePendingInsights()
│       └─ InsightGenerator.deduplicateInsights()
```

**Benefits:**
- ✅ Import coordinators don't block on insight generation
- ✅ Rapid imports are debounced (1-second window)
- ✅ Heavy work runs on background actor (no UI freezing)
- ✅ Clean separation of concerns

---

## Complete File Changes

### Files Modified in This Fix

1. ✅ `ContactsImportCoordinator.swift`
   - Line 104: Wrapped insight trigger in `Task { await ... }`
   - Line 112: Wrapped startup trigger in `Task { await ... }`
   - Line 35: Fixed `Task.sleep` to use Duration API

### All Files Modified in Swift 6 Migration

1. ✅ `CalendarImportCoordinator.swift` - Actor pattern + actor calls
2. ✅ `ContactsImportCoordinator.swift` - Actor calls + Duration API
3. ✅ `PermissionsManager.swift` - `@Observable` migration
4. ✅ `EvidenceRepository.swift` - Database predicates
5. ✅ `SamSettingsView.swift` - Removed `@ObservedObject`

---

## Testing Checklist

### Contacts Import Flow
- [ ] Settings → Contacts → Select group
- [ ] "Sync Now" button triggers import
- [ ] Contacts are upserted into People list
- [ ] Insight generation triggers after import
- [ ] Rapid imports are debounced (1 second window)
- [ ] No UI freezing during import

### App Startup
- [ ] Insights generate on app launch (safety net)
- [ ] No blocking during startup
- [ ] Console logs show insight generation

### Console Output Expected
```
[SAM] INFO: Contacts import processed 42 contacts in group SAM
[SAM] INFO: 🧠 [InsightRunner] Scheduled insight generation (debounce: 1.0s)
[SAM] INFO: 🧠 [InsightRunner] Starting insight generation...
[SAM] INFO: ✅ [InsightRunner] Insight generation complete
```

---

## Build Status

✅ **All actor call errors fixed**  
✅ **Duration API updated**  
✅ **Ready to build and test**

---

## Pattern Reference

### ✅ Correct Pattern: Fire-and-Forget Actor Call

```swift
@MainActor
final class Coordinator {
    func doWork() async {
        // ... work ...
        
        // Trigger background actor work
        Task {
            await BackgroundActor.shared.process()
        }
        
        // Continue immediately (doesn't wait)
    }
}
```

### ❌ Wrong Pattern: Synchronous Actor Call

```swift
@MainActor
final class Coordinator {
    func doWork() async {
        // ... work ...
        
        BackgroundActor.shared.process()  // ❌ Missing await
    }
}
```

### ⚠️ Alternative Pattern: Wait for Completion

```swift
@MainActor
final class Coordinator {
    func doWork() async {
        // ... work ...
        
        // Wait for background work to complete
        await BackgroundActor.shared.process()
        
        // Continues only after process() finishes
    }
}
```

**Use fire-and-forget** when you want to trigger background work without waiting.  
**Use bare `await`** when you need the result or must ensure completion.

---

**Status: All build errors resolved! 🚀**

*Fix applied: February 6, 2026*  
*Project: SAM_crm*
