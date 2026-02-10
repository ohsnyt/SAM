# Developer Fixture Deletion Crash Fix

## Problem

When clicking "Restore developer fixture" in the Development tab, the app would crash with:

```
SwiftData/BackingData.swift:249: Fatal error: This backing data was detached 
from a context without resolving attribute faults: 
PersistentIdentifier(...) - \SamInsight.kind
```

### Root Cause

The crash occurred due to a **race condition** between SwiftData deletion and SwiftUI view updates:

1. The fixture restore function deleted all `SamInsight` objects from the **main model context**
2. SwiftUI views (specifically `InsightCardView`) were still observing these insights
3. When the context saved, SwiftUI triggered a view update pass
4. During rendering, `InsightCardView.iconName` tried to access `insight.kind`
5. But the insight object was now **detached** (deleted) from the context
6. SwiftData couldn't fault in the `kind` property because the object was deleted
7. **CRASH** ❌

This is a classic SwiftData issue where views hold references to model objects that get deleted while the views are still active.

## Solution

The fix uses a **background context** for deletion operations and then resets the main context:

```swift
// Use a background context to avoid triggering view updates on main context
// during deletion
let bgContext = ModelContext(container)

do {
    // Perform all deletions in background context
    try await Task.detached {
        let insights = try bgContext.fetch(FetchDescriptor<SamInsight>())
        for insight in insights { bgContext.delete(insight) }
        // ... delete other entities ...
        try bgContext.save()
    }.value
    
    // Now reset the main context so views stop trying to access deleted objects
    modelContext.reset()
    
    // Small delay to let SwiftUI process the reset
    try? await Task.sleep(for: .milliseconds(100))
}
```

### Why This Works

1. **Background context deletion**: Deletions happen in a separate `ModelContext`, so the main context doesn't trigger immediate view updates during deletion
2. **Main context reset**: After deletion completes, we call `modelContext.reset()` which:
   - Discards all cached objects in the main context
   - Causes SwiftUI to stop observing the deleted objects
   - Forces views to re-fetch fresh data
3. **Brief delay**: The 100ms sleep gives SwiftUI time to process the reset and tear down any views that were displaying the deleted insights

## Key Takeaways

- **Never delete model objects that active views are observing** without proper coordination
- Use **background contexts** for bulk deletion operations
- Call `reset()` on the main context after bulk deletions to clear cached objects
- SwiftData's fault mechanism can't resolve attributes on deleted objects
- This pattern is particularly important for developer/testing tools that manipulate data while the UI is active

## Testing

To verify the fix:
1. Open the app and navigate to any view displaying insights
2. Go to Settings → Development
3. Click "Restore developer fixture"
4. Verify: No crash occurs ✅
5. Verify: New fixture data loads correctly ✅
