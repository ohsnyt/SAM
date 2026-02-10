# SwiftData Enum Storage Fix

**Date:** 2026-02-06  
**Issue:** Runtime crash during SwiftData schema validation  
**Error:** `Failed to validate \SamEvidenceItem.state.rawValue because rawValue is not a member of EvidenceTriageState`

## Problem

SwiftData in Swift 6.2 has a critical bug with `RawRepresentable` enum types stored directly as properties in `@Model` classes. When the schema validation runs (during the first fetch or context operation), it fails to recognize that enum types conforming to `RawRepresentable` have a `rawValue` property, causing a fatal runtime error.

### Symptoms

- App crashes on startup during the first SwiftData fetch
- Stack trace shows crash in `SwiftData/Schema.swift:346`
- Error message: `Fatal error: Failed to validate \SamEvidenceItem.state.rawValue because rawValue is not a member of EvidenceTriageState`
- Deleting the data store doesn't fix the issue (it's a schema validation problem, not data corruption)

### Original Code (Broken)

```swift
@Model
final class SamEvidenceItem {
    // ❌ This causes schema validation to fail
    var state: EvidenceTriageState
    
    init(state: EvidenceTriageState) {
        self.state = state
    }
}

enum EvidenceTriageState: String, Codable, CaseIterable {
    case needsReview
    case done
}
```

## Solution

Store the raw value directly and provide a computed property for type-safe enum access:

```swift
@Model
final class SamEvidenceItem {
    // ✅ Store raw value
    var stateRawValue: String
    
    // ✅ Computed property for type-safe access
    @Transient
    var state: EvidenceTriageState {
        get { EvidenceTriageState(rawValue: stateRawValue) ?? .needsReview }
        set { stateRawValue = newValue.rawValue }
    }
    
    init(state: EvidenceTriageState) {
        self.stateRawValue = state.rawValue
    }
}
```

### Key Points

1. **Store the raw value** (`String`, `Int`, etc.) as a regular property
2. **Make it `public` or `internal`** (not `private`) so predicates can access it
3. **Mark the computed property `@Transient`** so SwiftData ignores it during schema validation
4. **Initialize the raw value** in the initializer
5. **Update predicates** to use `stateRawValue` instead of `state.rawValue`

## Implementation Changes

### 1. Model Changes (`SAMModels.swift`)

```swift
// Before
var state: EvidenceTriageState

// After
var stateRawValue: String

@Transient
var state: EvidenceTriageState {
    get { EvidenceTriageState(rawValue: stateRawValue) ?? .needsReview }
    set { stateRawValue = newValue.rawValue }
}

// Initializer
init(state: EvidenceTriageState, ...) {
    self.stateRawValue = state.rawValue  // ✅ Changed
    // ...
}
```

### 2. Predicate Updates (`EvidenceRepository.swift`)

```swift
// Before (broken)
let predicate = #Predicate<SamEvidenceItem> { $0.state.rawValue == "needsReview" }

// After (works)
let predicate = #Predicate<SamEvidenceItem> { $0.stateRawValue == "needsReview" }

// Alternative pattern (also works)
let targetState = "needsReview"
let predicate = #Predicate<SamEvidenceItem> { $0.stateRawValue == targetState }
```

### 3. View Code

**No changes needed!** Views continue to use `item.state` and get the computed property transparently:

```swift
// All existing code continues to work
if item.state == .needsReview {
    // ...
}

item.state = .done  // Sets stateRawValue internally
```

### 4. Backup/Restore

**No changes needed!** The DTO layer reads and writes through the computed property:

```swift
// Snapshot
BackupEvidenceItem(from model: SamEvidenceItem) {
    self.state = model.state  // ✅ Uses computed getter
}

// Restore
func makeModel() -> SamEvidenceItem {
    SamEvidenceItem(state: state, ...)  // ✅ Initializer handles conversion
}
```

## Related Issues

This is distinct from (but related to) the known `#Predicate` enum issue documented in `ENUM_RAWVALUE_PREDICATE_FIX.md`:

- **That issue:** `#Predicate` can't expand enum cases as key paths
- **This issue:** SwiftData schema validation rejects enums entirely
- **Solution overlap:** Both are solved by storing raw values and using predicates on the raw storage

## Verification

After applying the fix:

1. ✅ App launches without crashing
2. ✅ Fixture seeding completes successfully
3. ✅ All queries and predicates work correctly
4. ✅ Views display and mutate state correctly
5. ✅ Backup/restore preserves state correctly
6. ✅ No changes needed to view code or DTO layer

## Lessons Learned

1. **SwiftData enum support is incomplete.** Avoid storing `RawRepresentable` enums directly in `@Model` classes.
2. **The error message is misleading.** "rawValue is not a member" suggests a coding error, but it's actually a SwiftData schema bug.
3. **The raw-value pattern is robust.** It works across predicates, views, backups, and migrations without requiring changes elsewhere.
4. **`@Transient` is critical.** Without it, SwiftData tries to persist both the raw value and the computed property, causing conflicts.

## Future Considerations

If Apple fixes this in a future SwiftData release, we can migrate back to direct enum storage:

1. Remove `@Transient` from `state`
2. Delete the `stateRawValue` property
3. Update the initializer
4. Update predicates to use `$0.state.rawValue` (with the captured-variable pattern)
5. Test thoroughly before releasing

However, the raw-value pattern is safe and performant, so there's no urgency to migrate back unless we need advanced features that require direct enum storage.

---

**Resolution:** ✅ **FIXED** — App now launches and runs correctly with raw-value enum storage pattern.
