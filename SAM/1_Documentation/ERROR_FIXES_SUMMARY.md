# Error Fixes Summary
**Date**: February 10, 2026  
**Author**: Assistant  

## Errors Fixed

### 1. PeopleListView.swift - Preview Syntax Issues

**Location**: Lines 283 and 318  
**Error**: `Type '()' cannot conform to 'View'`

**Architecture Coverage**: ⚠️ **Not documented** - This is a Swift syntax issue, not an architectural concern

**Root Cause**: 
- Preview closures with multiple statements need explicit `return` keyword
- SwiftUI expects the preview body to return a View

**Fix Applied**:
```swift
// BEFORE (❌ Error)
#Preview("With People") {
    let container = SAMModelContainer.shared
    // ... setup code ...
    PeopleListView()
        .modelContainer(container)
        .frame(width: 900, height: 600)
}

// AFTER (✅ Fixed)
#Preview("With People") {
    let container = SAMModelContainer.shared
    // ... setup code ...
    return PeopleListView()  // Added explicit return
        .modelContainer(container)
        .frame(width: 900, height: 600)
}
```

**Applied to**:
- `#Preview("With People")` at line ~281
- `#Preview("Empty")` at line ~318

---

### 2. PersonDetailView.swift - Preview Syntax Issue

**Location**: Line 283  
**Error**: `Type '()' cannot conform to 'View'`

**Architecture Coverage**: ⚠️ **Not documented** - Same Swift syntax issue as above

**Fix Applied**:
```swift
// BEFORE (❌ Error)
#Preview {
    let container = SAMModelContainer.shared
    // ... setup code ...
    NavigationStack {
        PersonDetailView(person: person)
            .modelContainer(container)
    }
    .frame(width: 700, height: 800)
}

// AFTER (✅ Fixed)
#Preview {
    let container = SAMModelContainer.shared
    // ... setup code ...
    return NavigationStack {  // Added explicit return
        PersonDetailView(person: person)
            .modelContainer(container)
    }
    .frame(width: 700, height: 800)
}
```

---

### 3. PeopleRepository.swift - Predicate Capturing Variable

**Location**: Line ~98 in `upsert(contact:)` method  
**Error**: `Type of expression is ambiguous without a type annotation` (macro-generated file)

**Architecture Coverage**: ✅ **Section 6.4: SwiftData Best Practices - Search/Filtering with Predicates**

**Root Cause**:
Swift 6 predicates cannot capture variables from outer scope. The predicate was trying to use `contact.identifier`:

```swift
// BROKEN: Captures contact.identifier from outer scope
predicate: #Predicate { $0.contactIdentifier == contact.identifier }
```

This is **explicitly documented** in context.md Section 6.4:

> **Search/Filtering with Predicates**:
> Swift 6 predicates can't capture outer scope variables. Use fetch-all + in-memory filter for simple searches.

**Fix Applied**:
```swift
// BEFORE (❌ Error - captures contact.identifier)
var descriptor = FetchDescriptor<SamPerson>(
    predicate: #Predicate { $0.contactIdentifier == contact.identifier }
)
descriptor.fetchLimit = 1

if let existing = try context.fetch(descriptor).first {
    // ...
}

// AFTER (✅ Fixed - fetch all, filter in memory)
let descriptor = FetchDescriptor<SamPerson>(
    predicate: #Predicate { $0.contactIdentifier != nil }
)

let allPeople = try context.fetch(descriptor)
let existing = allPeople.first { $0.contactIdentifier == contact.identifier }

if let existing = existing {
    // ...
}
```

**Performance Note**: 
- This change fetches all people with contactIdentifiers, then filters in memory
- For small datasets (typical CRM: <10,000 contacts), this is negligible
- Follows documented pattern in context.md Section 6.4
- More efficient than attempting complex predicate workarounds

---

## Architecture Documentation Updates Needed

### Issue: Preview Return Statements

**Current State**: Not documented in context.md

**Recommendation**: Add to Section 6.4 or create new Section 6.6 for "SwiftUI Preview Patterns"

**Suggested Addition**:

```markdown
### 6.6 SwiftUI Preview Patterns

**Multi-Statement Preview Closures**:
When preview closures contain setup code before returning the view, use explicit `return`:

```swift
// ❌ BROKEN - Type '()' cannot conform to 'View'
#Preview("My View") {
    let container = SAMModelContainer.shared
    // setup code...
    MyView()
        .modelContainer(container)
}

// ✅ WORKS - Explicit return statement
#Preview("My View") {
    let container = SAMModelContainer.shared
    // setup code...
    return MyView()
        .modelContainer(container)
}
```

**Single-Expression Previews** (no return needed):
```swift
// ✅ WORKS - Single expression, implicit return
#Preview("Simple") {
    MyView()
}
```
```

**Priority**: Low (syntax issue, not architectural)  
**Impact**: Prevents confusing compile errors in previews  
**Location**: Add after Section 6.5 (Store Singleton Pattern)

---

## Verification Checklist

- [x] All three errors addressed
- [x] Fixes follow clean architecture principles
- [x] Section 6.4 guidance correctly applied (predicate issue)
- [x] Comments added explaining Swift 6 workaround
- [x] No architectural violations introduced
- [x] Documentation gap identified (preview patterns)

---

## Files Modified

1. **PeopleListView.swift**
   - Line ~281: Added `return` to "With People" preview
   - Line ~318: Added `return` to "Empty" preview

2. **PersonDetailView.swift**
   - Line ~661: Added `return` to preview closure

3. **PeopleRepository.swift**
   - Lines 88-140: Refactored `upsert(contact:)` to avoid predicate variable capture
   - Added comment: "Swift 6: Can't capture contact.identifier in predicate"
   - Uses fetch-all + filter pattern from Section 6.4

---

## Testing Recommendations

### Unit Tests
```swift
@Test("Upsert creates new person")
func testUpsertCreate() async throws {
    let repo = PeopleRepository()
    repo.configure(container: testContainer)
    
    let dto = ContactDTO(
        identifier: "test-123",
        givenName: "Test",
        familyName: "User"
    )
    
    try repo.upsert(contact: dto)
    
    let people = try repo.fetchAll()
    #expect(people.count == 1)
    #expect(people.first?.contactIdentifier == "test-123")
}

@Test("Upsert updates existing person")
func testUpsertUpdate() async throws {
    let repo = PeopleRepository()
    repo.configure(container: testContainer)
    
    // First insert
    let dto1 = ContactDTO(identifier: "test-123", givenName: "John", familyName: "Doe")
    try repo.upsert(contact: dto1)
    
    // Update with same identifier
    let dto2 = ContactDTO(identifier: "test-123", givenName: "Jane", familyName: "Smith")
    try repo.upsert(contact: dto2)
    
    let people = try repo.fetchAll()
    #expect(people.count == 1) // Should still be 1 person
    #expect(people.first?.displayNameCache == "Jane Smith")
}
```

### Manual Testing
1. Build project (should compile without errors)
2. Open SwiftUI Previews
   - Verify "PeopleListView - With People" renders
   - Verify "PeopleListView - Empty" renders
   - Verify "PersonDetailView" renders
3. Run app and test contact import
   - Import contacts via "Import Now" button
   - Verify upsert logic works correctly
   - Check console for "Updated" vs "Created" messages

---

## Summary

**All errors fixed** using patterns already documented in our architecture (Section 6.4).

**Key Takeaway**: The predicate variable capture issue was already documented but not consistently applied. This fix brings `upsert(contact:)` in line with the `search(query:)` method, which already uses the fetch-all + filter pattern.

**Documentation Gap**: Preview return statements should be added to context.md for future reference, but this is a minor Swift syntax issue, not a core architectural concern.

**No Breaking Changes**: All fixes are internal implementation details. Public API remains unchanged.
