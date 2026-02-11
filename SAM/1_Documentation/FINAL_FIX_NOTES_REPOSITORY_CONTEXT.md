# FINAL FIX: NotesRepository Context Creation Bug

**Date**: February 11, 2026  
**Root Cause**: Computed property creating multiple contexts within single method  
**Status**: ✅ FIXED

---

## The Real Problem

The error wasn't about passing objects between **repositories** - it was about creating **multiple contexts within a single method**!

### Before (Broken) ❌

```swift
private var context: ModelContext {
    guard let container = container else {
        fatalError("...")
    }
    return ModelContext(container)  // ❌ Creates NEW context every time!
}

func create(...) throws -> SamNote {
    let allPeople = try context.fetch(...)      // Context A created
    let allContexts = try context.fetch(...)    // Context B created  
    let allEvidence = try context.fetch(...)    // Context C created
    
    note.linkedPeople = linkedPeople            // From Context A
    
    context.insert(note)                        // Context D created!
    // ❌ BOOM: Trying to insert note with relationships from A/B/C into Context D
}
```

Every time `context` was accessed, it created a **brand new ModelContext**. So within a single `create()` call:
- First `context.fetch()` → Context A
- Second `context.fetch()` → Context B
- Third `context.fetch()` → Context C
- `context.insert()` → Context D

The fetched objects belonged to contexts A/B/C, but we were trying to insert them into context D!

### After (Fixed) ✅

```swift
// No computed property anymore - removed entirely

func create(...) throws -> SamNote {
    guard let container = container else {
        throw RepositoryError.notConfigured
    }
    
    // Create context ONCE for the entire operation
    let context = ModelContext(container)
    
    // All fetches use the SAME context
    let allPeople = try context.fetch(...)      // Same context
    let allContexts = try context.fetch(...)    // Same context
    let allEvidence = try context.fetch(...)    // Same context
    
    note.linkedPeople = linkedPeople            // From same context
    
    context.insert(note)                        // Same context!
    // ✅ SUCCESS: Everything in same context
}
```

Now we create the context **once at the start** of each method and use it consistently throughout.

---

## Files Modified

### NotesRepository.swift - Complete Rewrite

**Changes**:

1. **Removed computed `context` property** entirely
2. **Added `RepositoryError` enum** for proper error handling
3. **Updated ALL methods** to create context once per method:
   - `fetchAll()` ✅
   - `fetch(id:)` ✅
   - `create()` ✅
   - `update()` ✅
   - `updateLinks()` ✅
   - `storeAnalysis()` ✅
   - `updateActionItem()` ✅
   - `delete()` ✅

**Pattern used** (in every method):
```swift
func someMethod() throws {
    guard let container = container else {
        throw RepositoryError.notConfigured
    }
    
    let context = ModelContext(container)  // Create once
    
    // All operations use this same context
    // ...
    
    try context.save()
}
```

---

## Why This Pattern?

Following `CLAUDE.md` architecture guidelines:

### ✅ Correct: One Context Per Method Call

```swift
// PeopleRepository (correct pattern)
func fetchAll() throws -> [SamPerson] {
    guard let container = container else {
        throw RepositoryError.notConfigured
    }
    
    let context = ModelContext(container)  // Fresh context per call
    let descriptor = FetchDescriptor<SamPerson>(...)
    return try context.fetch(descriptor)
}
```

This is safe because:
- Each method call gets its own isolated context
- Method completes and context is disposed
- No risk of using wrong context within the method

### ❌ Wrong: Computed Property Creating New Context Every Access

```swift
// NotesRepository (old, broken pattern)
private var context: ModelContext {
    return ModelContext(container)  // ❌ New context on every access
}

func create() {
    context.fetch(...)    // Context 1
    context.fetch(...)    // Context 2  ❌ Different!
    context.insert(...)   // Context 3  ❌ Different!
}
```

This fails because:
- Multiple contexts created within single method
- Objects from one context can't be used in another
- SwiftData throws "illegal attempt" error

### Why Not a Persistent Context?

We could store a single persistent context, but per-method contexts are better:

**Benefits of per-method contexts**:
- ✅ Thread-safe (each call isolated)
- ✅ Memory efficient (disposed after method)
- ✅ Clear lifecycle (method start → method end)
- ✅ Prevents stale data

**Downsides of persistent context**:
- ❌ Must manage lifecycle manually
- ❌ Can accumulate stale data
- ❌ Threading issues if accessed from multiple places
- ❌ Memory never freed until repository destroyed

---

## Testing

### Before Fix
```
Illegal attempt to insert a model in to a different model context.
Model PersistentIdentifier(...) is already bound to SwiftData.ModelContext
but insert was called on SwiftData.ModelContext
```

### After Fix
```
📝 [NotesRepository] Created note <UUID>
📝 [NoteEditorView] Created note <UUID>
📝 [NoteAnalysisService] Analyzed note: 2 people, 1 actions
📦 [EvidenceRepository] Created evidence: <title>
📬 [NoteAnalysisCoordinator] Created evidence item from note: <UUID>
✅ [NoteAnalysisCoordinator] Analyzed note <UUID>
```

**No errors!** ✅

---

## Lessons Learned

### Golden Rules for SwiftData Repository Context Management

1. **Never use computed properties for ModelContext**
   - Creates new context on every access
   - Breaks relationships within single method

2. **Create context once per method**
   - `let context = ModelContext(container)` at start of method
   - Use same context throughout method
   - Let it be disposed at method end

3. **Guard container existence**
   - Check for `nil` container before creating context
   - Throw proper error instead of force-unwrap

4. **Follow existing patterns**
   - PeopleRepository, EvidenceRepository, ContextsRepository all use per-method contexts
   - NotesRepository now matches this pattern

### Correct Repository Pattern

```swift
@MainActor
final class SomeRepository {
    private var container: ModelContainer?
    
    func configure(container: ModelContainer) {
        self.container = container
    }
    
    // ✅ Create context once per method
    func someMethod() throws {
        guard let container = container else {
            throw RepositoryError.notConfigured
        }
        
        let context = ModelContext(container)
        
        // All operations use this context
        let items = try context.fetch(...)
        context.insert(...)
        try context.save()
    }
}
```

---

## Related Code to Audit

Should check if other repositories have the same bug:

✅ **PeopleRepository** - Creates context per method (correct)  
✅ **EvidenceRepository** - Creates context per method (correct)  
✅ **ContextsRepository** - Creates context per method (correct)  
✅ **NotesRepository** - NOW FIXED (was using computed property)

All repositories now follow the same safe pattern.

---

**Status**: ✅ **COMPLETELY FIXED**

**Root Cause**: Computed `context` property creating new contexts on every access  
**Solution**: Create context once at start of each method, use consistently  
**Verification**: Create a note - should work cleanly with no context errors

**Date**: February 11, 2026
