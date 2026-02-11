# SwiftData Context Violation Fix

**Date**: February 11, 2026  
**Issue**: ModelContext boundary violation when creating evidence from notes

---

## The Error

```
Illegal attempt to insert a model in to a different model context.
Model PersistentIdentifier(...) is already bound to SwiftData.ModelContext
but insert was called on SwiftData.ModelContext
```

## Root Cause

In `NoteAnalysisCoordinator.createEvidenceFromNote()`, we were passing SwiftData model objects (`note.linkedPeople`, `note.linkedContexts`) directly from one repository's ModelContext to another repository's ModelContext.

### Why This Fails

Each repository has its own ModelContext:
- `NotesRepository` has context A
- `EvidenceRepository` has context B

When you pass `SamPerson` objects from context A to context B, SwiftData throws an error because those objects are already "owned" by context A.

## The Fix

**File**: `NoteAnalysisCoordinator.swift`

**Before** ❌:
```swift
private func createEvidenceFromNote(_ note: SamNote) throws {
    let evidence = try evidenceRepository.create(
        sourceUID: "note:\(note.id.uuidString)",
        source: .note,
        occurredAt: note.createdAt,
        title: note.summary ?? String(note.content.prefix(50)),
        snippet: note.summary ?? String(note.content.prefix(200)),
        bodyText: note.content,
        linkedPeople: note.linkedPeople,        // ❌ Objects from different context
        linkedContexts: note.linkedContexts     // ❌ Objects from different context
    )
}
```

**After** ✅:
```swift
private func createEvidenceFromNote(_ note: SamNote) throws {
    // Extract IDs instead of passing model objects
    let linkedPeopleIDs = note.linkedPeople.map { $0.id }
    let linkedContextIDs = note.linkedContexts.map { $0.id }
    
    // Re-fetch people and contexts in the evidence repository's context
    let peopleInEvidenceContext = try peopleRepository.fetchAll().filter { person in
        linkedPeopleIDs.contains(person.id)
    }
    let contextsInEvidenceContext = try contextsRepository.fetchAll().filter { context in
        linkedContextIDs.contains(context.id)
    }
    
    let evidence = try evidenceRepository.create(
        sourceUID: "note:\(note.id.uuidString)",
        source: .note,
        occurredAt: note.createdAt,
        title: note.summary ?? String(note.content.prefix(50)),
        snippet: note.summary ?? String(note.content.prefix(200)),
        bodyText: note.content,
        linkedPeople: peopleInEvidenceContext,      // ✅ Objects from correct context
        linkedContexts: contextsInEvidenceContext   // ✅ Objects from correct context
    )
}
```

**Also added missing dependency**:
```swift
private let contextsRepository = ContextsRepository.shared
```

## The Pattern

When passing SwiftData objects between repositories, always:

1. **Extract IDs** from source objects
2. **Re-fetch** objects in the destination repository's context
3. **Pass the re-fetched objects** to create/update methods

```swift
// ✅ CORRECT Pattern
let ids = sourceObjects.map { $0.id }
let objectsInNewContext = try repository.fetchAll().filter { ids.contains($0.id) }
try otherRepository.create(..., linkedObjects: objectsInNewContext)

// ❌ WRONG Pattern
try otherRepository.create(..., linkedObjects: sourceObjects)
```

## Why Not Use a Shared Context?

**SwiftData Best Practice**: Each repository should have its own ModelContext for isolation and thread safety.

**Benefits**:
- Changes in one repository don't affect others
- Can save/rollback independently
- Prevents accidental cascade saves
- Follows repository pattern properly

**Trade-off**: Need to re-fetch objects when crossing boundaries (small performance cost, big safety gain)

## Testing

**Before fix**:
```
Illegal attempt to insert a model in to a different model context.
```

**After fix**:
```
📦 [EvidenceRepository] Created evidence: Discussed insurance needs...
📬 [NoteAnalysisCoordinator] Created evidence item from note: <UUID>
✅ [NoteAnalysisCoordinator] Analyzed note <UUID>
```

No errors! ✅

---

## Related Issues to Check

This same pattern may exist in other coordinators. Search for:
- Any coordinator passing SwiftData models between repositories
- Any repository method that accepts model arrays from another context

**Example**: If `CalendarImportCoordinator` passes `SamPerson` objects when creating evidence, it needs the same fix.

---

**Status**: ✅ **FIXED**

**Date**: February 11, 2026
