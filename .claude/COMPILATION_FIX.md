# Compilation Errors: Fix Guide

## Issue Summary

You have **duplicate declarations** and **Swift 6 concurrency errors** that need fixing.

---

## Fix 1: Delete Duplicate File ✅ REQUIRED

**Problem:** Two `DebouncedInsightRunner` implementations exist:
- `.claude/DebouncedInsightRunner.swift` (duplicate, not used)
- `CalendarImportCoordinator.swift` (working implementation)

**Solution:** Delete the duplicate file manually.

### Steps:
1. Open Xcode
2. Navigate to `.claude/DebouncedInsightRunner.swift` in Project Navigator
3. Right-click → **Delete**
4. Choose **"Move to Trash"**

**This will fix 12+ errors immediately.**

---

## Fix 2: Check for SAMModelContainer.newContext()

The code references `SAMModelContainer.newContext()`. Verify this method exists.

**If it doesn't exist**, add it to your `SAMModelContainer`:

```swift
extension SAMModelContainer {
    static func newContext() -> ModelContext {
        ModelContext(shared)
    }
}
```

Or update the code to use:
```swift
let ctx = ModelContext(SAMModelContainer.shared)
```

---

## Errors After Fix 1

After deleting `.claude/DebouncedInsightRunner.swift`, you'll be left with **Swift 6 concurrency errors** in `ContactsSyncManager.swift`:

```
Main actor-isolated static property 'enableDebugLogging' cannot be accessed from outside of the actor
Main actor-isolated static method 'validate(_:requireSAMGroup:)' cannot be called from outside of the actor
```

These are **separate from Phase 2** and relate to Swift 6 strict concurrency checking.

---

## Fix 3: Swift 6 Concurrency Errors (ContactsSyncManager)

**Problem:** `ContactValidator` methods are `@MainActor` but being called from background contexts.

**Option A: Make ContactValidator nonisolated** (Recommended)

If `ContactValidator` doesn't need MainActor isolation:

```swift
// In ContactValidator definition:
struct ContactValidator {
    nonisolated static func validate(...) -> ValidationResult {
        // ... existing code ...
    }
    
    nonisolated static var enableDebugLogging: Bool {
        // ... existing code ...
    }
}
```

**Option B: Call from MainActor**

If it must be MainActor:

```swift
// In ContactsSyncManager, wrap the call:
await MainActor.run {
    let result = ContactValidator.validate(identifier, requireSAMGroup: filterByGroup)
    if result == .valid {
        validIDs.insert(identifier)
    }
}
```

---

## Quick Fix Summary

### Immediate (Required)
1. ✅ **Delete** `.claude/DebouncedInsightRunner.swift`
2. ✅ **Verify** `SAMModelContainer.newContext()` exists (or add it)
3. ✅ **Build** — most errors should be gone

### If Swift 6 Errors Remain
4. ⏳ **Fix** `ContactValidator` isolation (Option A or B above)

---

## Expected State After Fixes

### ✅ Working
- `DebouncedInsightRunner.shared` in `CalendarImportCoordinator.swift`
- `DevLogger.info()` and `DevLogger.error()`
- Both coordinators can call `.shared.run()`
- Insight generation triggers after imports

### ⏳ May Need Attention
- Swift 6 concurrency in `ContactsSyncManager` (separate issue)

---

## Testing After Fix

1. **Delete the file**
2. **Clean build folder** (⇧⌘K)
3. **Build** (⌘B)
4. **Run** (⌘R)
5. **Check console** for:
   ```
   [SAM] INFO: 🧠 [InsightRunner] Scheduled insight generation
   [SAM] INFO: 🧠 [InsightRunner] Starting insight generation...
   [SAM] INFO: ✅ [InsightRunner] Insight generation complete
   ```

---

## Why This Happened

During our session, I created `DebouncedInsightRunner.swift` as a standalone file, not realizing you already had a working implementation embedded in `CalendarImportCoordinator.swift`. 

The working implementation was already there and functional — I just needed to enhance the logging, which we did.

---

## Next Steps After Compilation Succeeds

1. **Test the system** (see `PHASE_2_COMPLETE.md`)
2. **Validate insights appear** in Awareness
3. **(Optional)** Task 5: Remove old code path from `AwarenessHost`
4. **Move to Phase 3** when ready

---

## Need Help?

If errors persist after deleting the file:
1. Post the **new error messages**
2. Check if `SAMModelContainer.newContext()` exists
3. Verify no other duplicate declarations

The duplicate file is the root cause of most errors. Delete it first! 🗑️

