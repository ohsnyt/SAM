# LinkContactSheet - Searchable Picker Redesign

## Problem

The original linking flow had a conceptual flaw: since SAM already imports **all contacts from the SAM group**, there's no need to open Contacts.app to search for a match. Every possible contact is already in the app's database.

### Original Flow Issues

1. **"Search Contacts App"** button opened Contacts.app, forcing the user to:
   - Switch apps
   - Find the contact manually
   - Add them to SAM group
   - Wait for sync
   - Return to SAM and try linking again

2. **"Create New Contact"** created a vCard and opened it in Contacts.app (still useful for truly new contacts)

3. **Merge buttons** only appeared for the top 3 duplicate matches

**Result:** Clunky multi-app workflow when the data was already available locally.

## Solution: Searchable In-App Picker

Replace the dual-button flow with a **unified searchable list** that shows:

1. **Suggested matches** at the top (based on name similarity via `PersonDuplicateMatcher`)
2. **Divider**
3. **All linked contacts** sorted alphabetically by last name

### Key Features

✅ **Search bar** - Filter contacts by name, address, or phone  
✅ **Smart suggestions** - Top 3 matches with confidence badges  
✅ **Visual hierarchy** - Suggested vs. all contacts clearly separated  
✅ **One-click linking** - Tap any contact to adopt its `contactIdentifier`  
✅ **Fallback option** - "Create New Contact" button if the contact doesn't exist yet  
✅ **Empty state** - Helpful message when search returns no results

## Implementation Details

### Data Flow

```
User clicks "Link" badge
    ↓
Confirm intent
    ↓
Run duplicate detection (PersonDuplicateMatcher)
    ↓
Show picker with:
  - Suggested matches (score ≥ 60%)
  - All linked contacts (sorted by last name)
```

### View Structure

```swift
VStack {
    // Header
    "Link [Name]"
    "Select a linked contact from your SAM group"
    
    // Search bar
    TextField with search icon and clear button
    
    // Scrollable list
    ScrollView {
        // Section 1: Suggested (if any)
        "SUGGESTED MATCHES"
        ForEach(suggestedMatches) { ... with "Match X%" badge }
        
        Divider()
        
        // Section 2: All contacts
        "ALL CONTACTS"
        ForEach(filteredAndSortedCandidates) { ... }
        
        // Empty state
        if empty: "No contacts found"
    }
    
    // Actions
    Cancel | Create New Contact
}
```

### Sorting Logic

**Suggested matches:** Sorted by **score descending** (highest match first)

**All contacts:** Sorted by **last name** using `localizedStandardCompare` for proper Unicode handling (e.g., "Müller" sorts correctly)

```swift
return filtered.sorted { a, b in
    let aLast = a.displayName.split(separator: " ").last.map(String.init) ?? a.displayName
    let bLast = b.displayName.split(separator: " ").last.map(String.init) ?? b.displayName
    return aLast.localizedStandardCompare(bLast) == .orderedAscending
}
```

### Filtering Logic

1. **Only linked contacts** - Filters out people without `contactIdentifier`
2. **Exclude self** - The person being linked doesn't appear in the list
3. **Search query** - Matches against:
   - Display name
   - Address line
   - Phone line

### Visual Design

**Suggested match row:**
```
┌─────────────────────────────────────────────────┐
│ ● John Smith                     [Match 85%]  ➤ │
│   123 Main St                                   │
└─────────────────────────────────────────────────┘
```

**Regular contact row:**
```
┌─────────────────────────────────────────────────┐
│ ● Jane Doe                                    ➤ │
│   jane@example.com                              │
└─────────────────────────────────────────────────┘
```

**Icons:**
- ● filled circle = linked (has `contactIdentifier`)
- ○ empty circle = unlinked (shouldn't appear in this picker)

## User Experience

### Before Redesign
1. Click unlinked badge
2. Click "Yes, Let's Link"
3. See 3 duplicate matches with merge buttons
4. Click "Search Contacts App"
5. Contacts.app opens
6. Find contact manually
7. Add to SAM group
8. Return to SAM
9. Wait for sync
10. Try linking again

**Steps:** 10+ steps, multiple apps

### After Redesign
1. Click unlinked badge
2. Click "Yes, Let's Link"
3. See searchable list with suggestions at top
4. Type to search (optional)
5. Click desired contact
6. Done ✅

**Steps:** 6 steps, single app

## Testing

### Test Case 1: Link to Suggested Match
1. Create unlinked person "Bob Smith"
2. Ensure linked contact "Robert Smith" exists in SAM group
3. Click unlinked badge → "Yes, Let's Link"
4. **Expected:**
   - "Robert Smith" appears in "SUGGESTED MATCHES" with "Match 90%" badge
   - Click "Robert Smith" → immediately links

### Test Case 2: Search and Link
1. Create unlinked person "Sarah Johnson"
2. Ensure 50+ linked contacts exist
3. Click unlinked badge → "Yes, Let's Link"
4. Type "sah" in search
5. **Expected:**
   - List filters to matching names
   - Click "Sarah Johnson" → immediately links

### Test Case 3: No Matches
1. Create unlinked person "Unique Name"
2. Click unlinked badge → "Yes, Let's Link"
3. **Expected:**
   - No suggested matches section
   - All contacts list shown
   - Can still search and select any contact

### Test Case 4: Empty State
1. Click unlinked badge → "Yes, Let's Link"
2. Type "zzzzz" in search
3. **Expected:**
   - Empty state: "No contacts found"
   - Suggestion: "Try adjusting your search"

### Test Case 5: Create New Contact
1. Click unlinked badge → "Yes, Let's Link"
2. Realize contact doesn't exist in SAM
3. Click "Create New Contact"
4. **Expected:**
   - vCard created with person's name
   - Opens in Contacts.app
   - User can complete creation there

## Code Changes

### LinkContactSheet.swift

**Removed:**
- `openContactPicker()` function (no longer needed)
- `ActionRowStyle` button style (no longer used)
- `chooseWithDuplicate` / `chooseWithoutDuplicate` enum cases
- Old `chooseView()` with action buttons

**Added:**
- `searchText` @State for search bar
- `.picker([DuplicateMatch])` unified enum case
- `pickerView(suggestedMatches:)` - Main list UI
- `contactRow(candidate:badge:)` - Reusable row component
- `filteredAndSortedCandidates` computed property
- `linkToContact()` helper function

**Modified:**
- `runDuplicateCheck()` - Always transitions to `.picker`
- Frame size: 480 → 520 width, 600 height (for scrollable list)

## Benefits

| Aspect | Before | After |
|--------|--------|-------|
| **Steps to link** | 10+ | 6 |
| **App switches** | 2+ | 0 (unless creating new) |
| **Search** | Manual in Contacts.app | Built-in, instant |
| **All contacts visible** | No (only top 3 dupes) | Yes (scrollable list) |
| **Sorting** | By match score only | Suggestions + alphabetical |
| **Feedback** | Unclear what to do | Clear list of options |

## Future Enhancements

1. **Recent contacts** - Show recently linked contacts at the top
2. **Frecency sorting** - Combine frequency + recency for smarter suggestions
3. **Fuzzy search** - Use Levenshtein distance for typo tolerance
4. **Group headers** - A, B, C... section headers for long lists
5. **Keyboard navigation** - Arrow keys + Enter to select
6. **Quick actions** - Swipe actions for merge/unlink

## Files Modified

- `LinkContactSheet.swift` — Complete UI redesign
- `context.md` — Will need updating to reflect new flow

## Status

✅ **Implementation Complete**  
🧪 **Ready for Testing**  
📝 **More intuitive than previous flow**

---

**Next Step:** Test the new searchable picker by linking an unlinked person.
