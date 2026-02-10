# ✅ Duplicate Type Declarations Fixed

## Problem

**Errors:**
```
Invalid redeclaration of 'InsightGroupKey'
Invalid redeclaration of 'InsightDedupeKey'
'InsightGroupKey' is ambiguous for type lookup in this context
```

## Root Cause

We created `InsightGeneratorTypes.swift` but there were **two copies** in the project:
1. `InsightGeneratorTypes.swift` (our creation)
2. `InsightGeneratorTypes 2.swift` (Xcode duplicate)

This caused the helper structs to be declared twice, making them ambiguous.

## Solution

**Moved the helper structs into `InsightGenerator.swift` itself:**

```swift
// InsightGenerator.swift (at end of file)

// MARK: - Helper Types

/// Helper struct for grouping evidence items by entity + signal kind.
/// Separated to avoid MainActor isolation inference issues.
struct InsightGroupKey: Hashable, Sendable {
    let personID: UUID?
    let contextID: UUID?
    let signalKind: SignalKind
}

/// Helper struct for identifying duplicate insights.
struct InsightDedupeKey: Hashable, Sendable {
    let personID: UUID?
    let contextID: UUID?
    let kind: InsightKind
}
```

## Why This Works

While it's **best practice** to put helper types in separate files to avoid isolation inference (as documented in our Swift 6 migration notes), in this case:

1. ✅ The structs are explicitly marked `Sendable`
2. ✅ They're defined **at module scope** (outside the actor body)
3. ✅ Swift won't infer MainActor isolation because they're not inside the actor

The separate file approach failed because of Xcode file management issues (duplicates).

## Action Required

### 1. Delete Duplicate Files in Xcode

In Xcode's file navigator, **delete both**:
- [ ] `InsightGeneratorTypes.swift`
- [ ] `InsightGeneratorTypes 2.swift`

**How:** Right-click → Delete → Move to Trash

### 2. Clean Build Folder

```
Cmd+Shift+K
```

This removes cached builds that reference the old duplicate files.

### 3. Build

```
Cmd+B
```

Should succeed with zero errors!

---

## Alternative: Separate File (If Preferred)

If you want to keep the separate file approach:

1. **Delete BOTH duplicate files** from Xcode
2. **Create ONE new file:** `InsightGeneratorTypes.swift`
3. **Add the struct definitions** (as shown above)
4. **Remove the structs** from the end of `InsightGenerator.swift`

**Benefits of separate file:**
- ✅ Cleaner organization
- ✅ Follows best practices
- ✅ Avoids potential isolation inference

**Downside:**
- ⚠️ File management complexity (as we just experienced)

---

## Current Status

✅ **Helper structs added to `InsightGenerator.swift`**  
🔄 **You must delete the duplicate files in Xcode**  
🔄 **Then clean build folder**  
🔄 **Then build should succeed**

---

## File Changes

### Modified
- ✅ `InsightGenerator.swift` - Added helper structs at end

### To Delete (in Xcode)
- ❌ `InsightGeneratorTypes.swift`
- ❌ `InsightGeneratorTypes 2.swift`

---

## Testing After Fix

- [ ] Clean build succeeds
- [ ] No "ambiguous type" errors
- [ ] No "invalid redeclaration" errors
- [ ] Insight generation works at runtime
- [ ] Deduplication works at runtime

---

**Status: Awaiting manual cleanup of duplicate files in Xcode, then build should succeed!**

*Fix applied: February 6, 2026*  
*Project: SAM_crm*
