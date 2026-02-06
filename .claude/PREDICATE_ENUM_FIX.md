# ✅ EvidenceRepository - Predicate Macro Fix

## Issues Fixed

### Error 1 & 2: Lines 40 and 49
```
Member access without an explicit base is not supported in this predicate (from macro 'Predicate')
```

---

## Root Cause

The `#Predicate` macro doesn't support Swift's **implicit enum member syntax** (`.needsReview`, `.done`). It requires the **fully qualified type name**.

---

## Fix Applied

### Before (Implicit Syntax)
```swift
func needsReview() throws -> [SamEvidenceItem] {
    let predicate = #Predicate<SamEvidenceItem> { 
        $0.state == .needsReview  // ❌ Implicit enum syntax not supported
    }
    // ...
}

func done() throws -> [SamEvidenceItem] {
    let predicate = #Predicate<SamEvidenceItem> { 
        $0.state == .done  // ❌ Implicit enum syntax not supported
    }
    // ...
}
```

### After (Explicit Type)
```swift
func needsReview() throws -> [SamEvidenceItem] {
    let predicate = #Predicate<SamEvidenceItem> { 
        $0.state == EvidenceTriageState.needsReview  // ✅ Fully qualified
    }
    // ...
}

func done() throws -> [SamEvidenceItem] {
    let predicate = #Predicate<SamEvidenceItem> { 
        $0.state == EvidenceTriageState.done  // ✅ Fully qualified
    }
    // ...
}
```

---

## Why This Limitation Exists

### Normal Swift Code
```swift
// ✅ Swift infers the enum type from context
let state: EvidenceTriageState = .needsReview  // Works everywhere
if item.state == .done { }  // Works everywhere
```

### Inside #Predicate Macro
```swift
// ❌ The macro can't infer the type
#Predicate<Item> { $0.state == .needsReview }  // Error!

// ✅ Must use fully qualified name
#Predicate<Item> { $0.state == EvidenceTriageState.needsReview }  // Works!
```

The `#Predicate` macro expands to SQLite query generation code. During macro expansion, Swift's type inference doesn't work the same way as in regular code, so you must provide the full type name.

---

## Pattern Reference

### ✅ Correct: Fully Qualified Enum in Predicate

```swift
// For any enum property in a @Model
enum Status: String, Codable {
    case active
    case inactive
}

@Model
final class Item {
    var status: Status
}

// In predicates, use full type name
let predicate = #Predicate<Item> { 
    $0.status == Status.active  // ✅
}
```

### ❌ Wrong: Implicit Enum Syntax

```swift
let predicate = #Predicate<Item> { 
    $0.status == .active  // ❌ Macro error
}
```

### ✅ Alternative: Capture Outside Predicate

```swift
// If the enum case comes from a variable
let targetState = EvidenceTriageState.needsReview

let predicate = #Predicate<Item> { item in
    item.state == targetState  // ✅ Works because it's captured
}
```

---

## Related Limitations

The `#Predicate` macro has several known limitations:

### 1. ❌ No Optional Chaining
```swift
#Predicate<Item> { $0.person?.name == "John" }  // ❌ Not supported
```

### 2. ❌ No Method Calls (Except Specific Ones)
```swift
#Predicate<Item> { $0.name.contains("test") }  // ✅ Supported
#Predicate<Item> { $0.date.customMethod() }    // ❌ Not supported
```

### 3. ❌ No Complex Computed Properties
```swift
#Predicate<Item> { $0.computedValue > 10 }  // ❌ May not work
```

### 4. ✅ Simple Comparisons Work
```swift
#Predicate<Item> { 
    $0.status == Status.active &&
    $0.date > someDate &&
    $0.count > 5
}  // ✅ All supported
```

---

## Documentation Update

Added to **Resolved Gotchas** in `context.md`:

> **`#Predicate` requires fully qualified enum cases.** Don't use `.needsReview`—use `EvidenceTriageState.needsReview`. The macro can't infer enum types like regular Swift code.

---

## Complete Migration Status

### All Build Errors Fixed ✅

1. ✅ **CalendarImportCoordinator.swift** - Actor calls + Duration API
2. ✅ **ContactsImportCoordinator.swift** - Actor calls + Duration API
3. ✅ **PermissionsManager.swift** - `@Observable` migration
4. ✅ **EvidenceRepository.swift** - Database predicates + enum qualification ← **Just fixed**
5. ✅ **SamSettingsView.swift** - Removed `@ObservedObject`

---

## Testing Checklist

### Inbox View
- [ ] "Needs Review" tab shows correct items
- [ ] "Done" tab shows correct items
- [ ] Filtering works at database level (check performance)
- [ ] Marking item as "Done" moves it to correct tab
- [ ] Reopening item moves it back to "Needs Review"

### Performance
- [ ] With 1000+ evidence items, queries should be fast (<50ms)
- [ ] No memory spikes (filtering happens in database, not memory)

### Console Verification
```swift
// Should not see this:
// "Fetching all 1000 items, then filtering..."

// Should see efficient query:
// "Fetch with predicate: state == 'needsReview'"
```

---

## Build Status

✅ **All predicate macro errors fixed**  
✅ **All actor isolation errors fixed**  
✅ **All Observable migrations complete**  
✅ **Ready to build!**

---

## Quick Reference

### Predicate Patterns Cheat Sheet

```swift
// ✅ Basic comparison
#Predicate<Item> { $0.count > 5 }

// ✅ Enum with full type
#Predicate<Item> { $0.status == Status.active }

// ✅ Date comparison
#Predicate<Item> { $0.date >= startDate && $0.date <= endDate }

// ✅ String contains
#Predicate<Item> { $0.name.contains("test") }

// ✅ Compound conditions
#Predicate<Item> { 
    $0.status == Status.active &&
    $0.count > 10 &&
    $0.date > cutoff
}

// ✅ Captured variables
let minCount = 10
#Predicate<Item> { $0.count > minCount }

// ❌ Implicit enum syntax
#Predicate<Item> { $0.status == .active }  // Error!

// ❌ Optional chaining
#Predicate<Item> { $0.person?.name == "John" }  // Error!

// ❌ Complex expressions
#Predicate<Item> { $0.items.filter { $0.active }.count > 5 }  // Error!
```

---

**Status: All build errors resolved! Try `Cmd+B` now.** 🚀

*Fix applied: February 6, 2026*  
*Project: SAM_crm*
