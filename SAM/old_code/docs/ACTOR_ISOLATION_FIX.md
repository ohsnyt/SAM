# Swift 6 Actor Isolation Fix - Final Solution

## Root Cause Identified

The errors were caused by calling `SAMModelContainer.newContext()` from inside a `Task.detached` block (nonisolated context) in `DebouncedInsightRunner`:

```swift
Task.detached {
    let ctx = SAMModelContainer.newContext()  // ← ERROR: MainActor isolated
    let generator = InsightGenerator(context: ctx)
    await generator.generatePendingInsights()
}
```

Swift's actor isolation inference saw that `SAMModelContainer` had a `@MainActor` method in an extension (`seedOnFirstLaunch()`), so it inferred the entire enum—including `shared` and `newContext()`—as MainActor-isolated.

## The Fix: Separate MainActor Code

Move the `@MainActor` method out of the enum entirely to avoid contamination:

### Before (Broken)
```swift
enum SAMModelContainer {
    static let shared: ModelContainer = { ... }()
    static func newContext() -> ModelContext { ... }
}

extension SAMModelContainer {
    @MainActor static func seedOnFirstLaunch() { ... }
}
```

### After (Fixed)
```swift
enum SAMModelContainer {
    static let shared: ModelContainer = { ... }()
    static func newContext() -> ModelContext { ... }
}

// Free function - no contamination
@MainActor
func seedModelContainerOnFirstLaunch() {
    let ctx = SAMModelContainer.newContext()
    SAMStoreSeed.seedIfNeeded(into: ctx)
}
```

## Changes Made

### 1. `SAMModelContainer.swift`
- Removed the `@MainActor` extension
- Created free function `seedModelContainerOnFirstLaunch()` 
- Enum is now fully nonisolated

### 2. `SAM_crmApp.swift`
- Changed call from `SAMModelContainer.seedOnFirstLaunch()` to `seedModelContainerOnFirstLaunch()`

### 3. `InsightGeneratorTypes.swift` (NEW FILE)
- Moved `InsightGroupKey` and `InsightDedupeKey` out of `InsightGenerator.swift`
- Prevents actor isolation contamination from SwiftData types

### 4. `InsightGenerator.swift`
- Removed helper type definitions (now in separate file)
- Actor remains clean

## Why This Works

1. **No MainActor methods in the enum** = No isolation inference
2. **Free function** = Isolated independently, doesn't taint other types
3. **Separate helper types file** = No actor context contamination
4. **`ModelContainer` is Sendable** = Safe to access from any context

## Key Lesson

**Extensions with actor-isolated methods taint the entire type.** Even if your enum/struct starts with no isolation, adding a `@MainActor` method via extension will cause Swift to infer MainActor isolation for **all** static members, including those defined in the primary declaration.

**Solution:** Keep actor-isolated code in free functions or separate types.

## Testing
After these changes:
- ✅ `SAMModelContainer.newContext()` callable from `Task.detached`
- ✅ `InsightGenerator` helper types work in dictionary operations
- ✅ No actor isolation errors

## Files to Add to Xcode
Don't forget to add `InsightGeneratorTypes.swift` to your project!
