# Navigation Architecture Refactor

**Date:** February 10, 2026  
**Issue:** Phantom padding in PersonDetailView due to nested NavigationSplitView  
**Solution:** Flattened navigation hierarchy (Option 3)

## Problem

The app had **nested** `NavigationSplitView` instances:
1. **AppShellView**: Sidebar (Intelligence/Relationships) → Detail (PeopleListView)
2. **PeopleListView**: People List → Person Detail

This created a well-documented SwiftUI bug where the collapsed width of the first sidebar appears as phantom padding on the left side of PersonDetailView.

## Solution

Flattened the navigation to use a **single** three-column `NavigationSplitView` when in the People section:

```
Sidebar → People List → Person Detail
```

Other sections continue to use two-column layout.

## Changes Made

### 1. AppShellView.swift

**Added:**
- `@State private var selectedPersonID: UUID?` - Manages person selection at the app level
- `@State private var columnVisibility: NavigationSplitViewVisibility = .all` - Controls column visibility
- Conditional body that shows:
  - **Three-column layout** for "people" section
  - **Two-column layout** for other sections
- `peopleDetailView` - New view builder for the person detail column
- `PeopleDetailContainer` - Helper view that fetches a person by ID and displays PersonDetailView

**Modified:**
- Removed "people" case from `detailView` switch statement
- `PeopleListView()` now receives `selectedPersonID: $selectedPersonID` binding

### 2. PeopleListView.swift

**Added:**
- `@Binding var selectedPersonID: UUID?` - Accepts selection binding from parent

**Removed:**
- Entire `NavigationSplitView` wrapper (was creating the nested navigation)
- `detailContent` view builder (now handled by AppShellView)
- `@State private var selectedPersonID: UUID?` (moved to AppShellView)

**Modified:**
- `body` now directly shows the list content (no NavigationSplitView wrapper)
- Previews updated to pass `.constant(nil)` binding and wrap in NavigationStack

### 3. PersonDetailView.swift

**No changes required** - Works perfectly as-is!

## Architecture Benefits

✅ **No phantom padding** - Single NavigationSplitView means no nested sidebar artifacts  
✅ **Native macOS behavior** - Three-column layout is standard for macOS apps  
✅ **Better state management** - Selection managed at appropriate level (AppShellView)  
✅ **No SwiftData/Concurrency impact** - Pure view hierarchy change  
✅ **Maintains existing Actor isolation** - PeopleRepository and ContactsImportCoordinator unchanged

## Testing Checklist

- [ ] Phantom padding is gone when sidebar is collapsed
- [ ] Person selection works correctly
- [ ] Search functionality still works
- [ ] Import contacts still works
- [ ] Person detail loads all contact information
- [ ] Navigation state persists across app launches (sidebar selection)
- [ ] Column resizing works properly
- [ ] Empty states display correctly

## Future Considerations

When implementing Contexts (Phase G), use the same pattern:
- Add `@State private var selectedContextID: UUID?` to AppShellView
- Create three-column layout for "contexts" section
- Pass binding to ContextsListView

This establishes a consistent pattern across all list-detail sections.
