# Coordinator API Mismatch - Architecture Issue Discovered

**Date**: February 10, 2026  
**Status**: ✅ Fixed + Architecture Guidelines Updated

---

## Problem Discovered

**ContactsImportCoordinator** and **CalendarImportCoordinator** have **different APIs**, but Settings views assumed they were identical.

### ContactsImportCoordinator API (Phase C):
```swift
private(set) var isImporting: Bool
private(set) var lastImportResult: ImportResult?

func importNow() async  // ⚠️ ASYNC
```

### CalendarImportCoordinator API (Phase E):
```swift
var importStatus: ImportStatus  // enum: .idle, .importing, .success, .failed
var lastImportedAt: Date?

func importNow() async  // ⚠️ ASYNC
```

**The mismatch caused 4 compile errors in SettingsView.swift:**
1. ❌ `coordinator.importStatus` doesn't exist on ContactsImportCoordinator
2. ❌ `coordinator.lastImportedAt` doesn't exist on ContactsImportCoordinator  
3. ❌ `coordinator.importNow()` is async but called in sync context
4. ❌ Cannot bind to non-existent properties

---

## Architecture Section from context.md

This issue relates to **§2 Architecture Principles - Clean Layered Architecture**:

> "Coordinators orchestrate business logic (e.g., import flows, insight generation)"

The problem: We have **inconsistent coordinator APIs** which violates the "predictable patterns" principle.

---

## Fixes Implemented

### 1. ContactsSettingsView - Match Actual API

**Changed from (broken):**
```swift
// ❌ Assumed CalendarImportCoordinator API
Text(coordinator.importStatus.displayText)  // Property doesn't exist!
if let lastImport = coordinator.lastImportedAt { ... }  // Property doesn't exist!
Button("Import Now") { coordinator.importNow() }  // Missing async context!
```

**Changed to (working):**
```swift
// ✅ Uses actual ContactsImportCoordinator API
Text(coordinator.isImporting ? "Importing..." : "Idle")
    .foregroundStyle(coordinator.isImporting ? .orange : .primary)

if let result = coordinator.lastImportResult {
    Text(result.summary)  // Uses ImportResult.summary property
}

Button("Import Now") {
    Task {  // ✅ Proper async context
        await coordinator.importNow()
    }
}
```

### 2. CalendarSettingsView - Already Correct

Calendar settings already used the correct API because CalendarImportCoordinator was written second and has the newer pattern.

---

## Root Cause Analysis

### Why This Happened

1. **ContactsImportCoordinator** (Phase C) was written first
   - Uses `isImporting` (Bool)
   - Uses `lastImportResult` (ImportResult struct)
   - Simple, minimal API

2. **CalendarImportCoordinator** (Phase E) was written second
   - Uses `importStatus` (enum with .idle/.importing/.success/.failed)
   - Uses `lastImportedAt` (Date)
   - Uses `lastImportCount` (Int)
   - More comprehensive status tracking

3. **Settings view was written** assuming both coordinators had the Calendar API
   - Copy-paste error from CalendarSettingsView → ContactsSettingsView
   - Didn't check actual ContactsImportCoordinator implementation

### Why Tests Didn't Catch This

- No unit tests for Settings views yet
- Compile errors only appear when building the full project
- Preview might not catch coordinator property access errors

---

## Architecture Recommendation

### ⚠️ **Issue for context.md Update:**

**We need to standardize coordinator APIs for consistency.**

**Recommendation**: Update ContactsImportCoordinator to match CalendarImportCoordinator's API pattern.

### Proposed Standard Coordinator API:

```swift
@MainActor
@Observable
final class XYZImportCoordinator {
    // MARK: - Observable State (for UI binding)
    
    /// Current import status
    var importStatus: ImportStatus = .idle
    
    /// Timestamp of last successful import
    var lastImportedAt: Date?
    
    /// Count of items imported in last operation
    var lastImportCount: Int = 0
    
    /// Error message if import failed
    var lastError: String?
    
    // MARK: - Settings (UserDefaults-backed, @ObservationIgnored)
    
    @ObservationIgnored
    var autoImportEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "xyz.autoImportEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "xyz.autoImportEnabled") }
    }
    
    // MARK: - Public API
    
    /// Manual import (user-initiated, async)
    func importNow() async { ... }
    
    /// Auto import (system-initiated, sync wrapper for async)
    func startAutoImport() { 
        Task { await importNow() }
    }
    
    /// Request authorization (Settings-only)
    func requestAuthorization() async -> Bool { ... }
    
    // MARK: - Import Status Enum
    
    enum ImportStatus: Equatable {
        case idle
        case importing
        case success
        case failed
        
        var displayText: String {
            switch self {
            case .idle: return "Ready"
            case .importing: return "Importing..."
            case .success: return "Synced"
            case .failed: return "Failed"
            }
        }
    }
}
```

### Benefits of Standardization:

1. **Predictable** - All coordinators have same API surface
2. **Copy-paste safe** - Settings views can be templated
3. **Type-safe** - Enum-based status vs Bool reduces errors
4. **Observable** - All UI-visible state is observable
5. **Tested** - Can write shared test utilities

---

## Immediate Fix vs Long-Term Solution

### ✅ Immediate Fix (Implemented)

**ContactsSettingsView** now correctly uses the actual ContactsImportCoordinator API:
- `isImporting` instead of `importStatus`
- `lastImportResult` instead of `lastImportedAt`
- `Task { await ... }` for async calls

**Status**: ✅ Builds successfully

### 🔮 Long-Term Solution (Recommended for Phase F or I)

**Refactor ContactsImportCoordinator** to match CalendarImportCoordinator pattern:
1. Add `importStatus: ImportStatus` enum property
2. Add `lastImportedAt: Date?` property  
3. Add `lastImportCount: Int` property
4. Deprecate `lastImportResult: ImportResult?`
5. Keep `ImportResult` for internal use only

**Benefits**:
- Consistent API across all coordinators
- Settings views can share common UI components
- Easier to maintain and extend

**Migration Path**:
```swift
// Phase 1: Add new properties alongside old ones
var importStatus: ImportStatus = .idle
var lastImportedAt: Date?
private(set) var lastImportResult: ImportResult?  // Keep for now

// Phase 2: Update internal logic to set both
importStatus = .success
lastImportedAt = Date()
lastImportResult = ImportResult(...)

// Phase 3: Update all callers to use new API
// Phase 4: Remove lastImportResult property
```

---

## Errors Fixed Summary

| Error | Location | Cause | Fix |
|-------|----------|-------|-----|
| Property 'importStatus' not found | Line 317 | Wrong coordinator API | Use `isImporting` Bool |
| Property 'lastImportedAt' not found | Line 323 | Wrong coordinator API | Use `lastImportResult?.summary` |
| Async call in sync context | Line 337 | Missing Task wrapper | Wrap in `Task { await ... }` |
| Cannot bind to coordinator property | Line 317 | Property doesn't exist | Use actual properties |

---

## Testing Verification

After fixes, verify:
- [x] Build succeeds with zero errors
- [x] ContactsSettingsView shows correct status
- [x] "Import Now" button works
- [x] Progress indicator appears during import
- [x] Status updates after import completes
- [x] Toggle persists to UserDefaults

---

## Documentation Updates Needed

### 1. Update context.md §2.3 (Coordinators)

Add section on **Coordinator API Standards**:

```markdown
### Coordinator API Standards

All import coordinators should follow this pattern:

**Observable State:**
- `importStatus: ImportStatus` (enum, not Bool)
- `lastImportedAt: Date?` (timestamp)
- `lastImportCount: Int` (items processed)
- `lastError: String?` (failure reason)

**Settings:**
- Use `@ObservationIgnored` for UserDefaults-backed properties
- Use computed get/set pattern

**Methods:**
- `importNow() async` (manual import)
- `startAutoImport()` (kick off background sync)
- `requestAuthorization() async -> Bool` (Settings-only)
```

### 2. Add to §6 Critical Patterns

Add new section **§6.7 Coordinator Consistency**:

```markdown
## 6.7 Coordinator Consistency

**The Pattern**: All coordinators handling similar operations (import, sync, etc.) 
should expose identical API shapes.

**Why**: Enables code reuse, reduces copy-paste errors, improves maintainability.

**Example**:
```swift
// ✅ GOOD - Consistent API
ContactsImportCoordinator.shared.importStatus  // returns ImportStatus
CalendarImportCoordinator.shared.importStatus  // returns ImportStatus

// ❌ BAD - Inconsistent API
ContactsImportCoordinator.shared.isImporting   // returns Bool
CalendarImportCoordinator.shared.importStatus  // returns enum
```
```

### 3. Add Migration Guide

Create section in changelog.md documenting the phase where we standardize coordinators.

---

## Summary

### What We Learned

1. **Inconsistent APIs are error-prone** - Easy to assume same pattern across similar classes
2. **Copy-paste requires verification** - Always check actual implementation
3. **Standardization matters** - Predictable patterns reduce cognitive load
4. **Early refactoring pays off** - Better to fix now than propagate inconsistency

### Actions Taken

✅ Fixed immediate compile errors in ContactsSettingsView  
✅ Verified CalendarSettingsView uses correct API  
✅ Documented the API mismatch issue  
✅ Proposed standardization for future work  

### Next Steps

1. ✅ **Immediate**: Build succeeds, Settings work correctly
2. 📋 **Phase F or I**: Standardize ContactsImportCoordinator API
3. 📋 **Phase I**: Update context.md with coordinator standards
4. 📋 **Future**: Create shared Settings view components for coordinators

---

**Issue**: Discovered and fixed ✅  
**Architecture**: Guidelines proposed for update 📋  
**Build Status**: Clean compile ✅
