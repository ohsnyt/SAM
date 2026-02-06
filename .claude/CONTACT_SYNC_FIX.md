# 🔧 Fix: Manual Contact Sync Creates Duplicates

## Problem

When clicking "Sync Now" to import contacts from the SAM group:
- ❌ Contacts don't sync automatically
- ❌ Manual sync creates duplicate `SamPerson` records
- ❌ Every sync adds more duplicates
- ❌ No deduplication during import

## Root Cause

The original contact import code was:
1. Fetching all contacts from the SAM group
2. Creating a **new** `SamPerson` for each contact
3. **Not checking** if that person already exists in SwiftData
4. Resulting in duplicates on every sync

## Solution

Created a new **upsert-based import system** that deduplicates:

### 1. ContactsImporter (New)

**Deduplication Strategy:**

For each contact in the SAM group:
1. **Check by contactIdentifier** — Does a `SamPerson` with this identifier already exist?
   - If yes → Skip (already linked)
2. **Check by canonical name** — Does an unlinked `SamPerson` with matching name exist?
   - If yes → Link it (set `contactIdentifier`)
3. **Check by email** — Does an unlinked `SamPerson` with matching email exist?
   - If yes → Link it
4. **No match** — Create new `SamPerson`

**Result:** No duplicates created, existing people are linked instead.

### 2. ContactsSyncView (New)

Replacement UI for "Sync Now" that:
- Shows progress during sync
- Displays results: "X new, Y linked"
- Shows last sync timestamp
- Handles errors gracefully

---

## Usage

### Replace Your "Sync Now" Button

**Old code (creates duplicates):**
```swift
Button("Sync Now") {
    // Your old sync code that creates duplicates
}
```

**New code (deduplicates):**
```swift
Button("Sync Now") {
    showingSyncSheet = true
}
.sheet(isPresented: $showingSyncSheet) {
    ContactsSyncView()
}
```

### Programmatic Import

```swift
let importer = ContactsImporter(modelContext: modelContext)

// Import from SAM group
let result = try await importer.importFromSAMGroup()
print("Imported \(result.imported) new, linked \(result.updated) existing")

// Or import all contacts (not just SAM group)
let result = try await importer.importAllContacts()
```

---

## How Deduplication Works

### Example: Syncing "John Smith"

**Scenario 1: Person already linked**
```
SwiftData: SamPerson(displayName: "John Smith", contactIdentifier: "ABC123")
Contact:   CNContact(identifier: "ABC123", name: "John Smith")

Result: Skip (already linked) ✅
```

**Scenario 2: Person exists but unlinked**
```
SwiftData: SamPerson(displayName: "John Smith", contactIdentifier: nil)
Contact:   CNContact(identifier: "ABC123", name: "John Smith")

Result: Link existing person (set contactIdentifier = "ABC123") ✅
Outcome: Updated = 1
```

**Scenario 3: Person doesn't exist**
```
SwiftData: (no matching person)
Contact:   CNContact(identifier: "ABC123", name: "John Smith")

Result: Create new SamPerson ✅
Outcome: Imported = 1
```

### Canonical Name Matching

Names are normalized for matching:
- Lowercase: "John Smith" → "john smith"
- Remove punctuation: "O'Brien" → "obrien"
- Normalize whitespace: "John  Smith" → "john smith"

This catches variations like:
- "John Smith" vs. "john smith"
- "O'Brien" vs. "OBrien"
- Extra spaces

---

## Fixing Existing Duplicates

If you already have duplicates from previous syncs:

### Option 1: Use DeduplicatePeopleView
```swift
// You already have this view
NavigationLink("Fix Duplicates") {
    DeduplicatePeopleView()
}
```

### Option 2: Use DuplicatePersonCleaner
```swift
let cleaner = DuplicatePersonCleaner(modelContext: modelContext)
let count = try cleaner.cleanAllDuplicates()
print("Merged \(count) duplicates")
```

### Option 3: ContactsSyncManager Auto-Dedupe
The `ContactsSyncManager` now auto-deduplicates after permission is granted, so duplicates should be cleaned on next launch.

---

## Testing

### Step 1: Clean State
1. Use `DeduplicatePeopleView` to merge existing duplicates
2. Verify no duplicates remain

### Step 2: Test Sync
1. Delete a `SamPerson` that has a matching contact in the SAM group
2. Click "Sync Now"
3. **Expected:** Person is re-created (Imported = 1)

### Step 3: Test Update
1. Unlink a person (clear `contactIdentifier`)
2. Click "Sync Now"
3. **Expected:** Person is linked (Updated = 1)

### Step 4: Test Duplicate Prevention
1. Click "Sync Now"
2. Click "Sync Now" again
3. **Expected:** No new people created, no changes (Imported = 0, Updated = 0)

---

## Console Output (Debug Mode)

The importer doesn't log by default, but you can add logging:

```swift
if ContactSyncConfiguration.enableDebugLogging {
    print("📱 ContactsImporter: Processing \(contacts.count) contacts")
    print("📱 ContactsImporter: Imported \(importedCount), Updated \(updatedCount)")
}
```

---

## Configuration

### Import All Contacts vs. SAM Group Only

**Default:** Import from SAM group only (safer)

To import all contacts:
```swift
let result = try await importer.importAllContacts()
```

**Warning:** Importing all contacts could create hundreds/thousands of `SamPerson` records. Only do this if you want your entire address book in SAM.

---

## Files Created

1. **ContactsImporter.swift** — Upsert-based import with deduplication
2. **ContactsSyncView.swift** — Replacement UI for "Sync Now"
3. **CONTACT_SYNC_FIX.md** — This documentation

---

## Migration Plan

### Phase 1: Fix Existing Duplicates
1. Run deduplication to merge existing duplicates
2. Verify no duplicates remain

### Phase 2: Replace Sync Button
1. Replace your old "Sync Now" button with `ContactsSyncView`
2. Test that new syncs don't create duplicates

### Phase 3: Monitor
1. Enable debug logging temporarily
2. Watch console during syncs
3. Verify imported/updated counts make sense

---

## Summary

✅ **Created:** `ContactsImporter` with deduplication  
✅ **Created:** `ContactsSyncView` with better UX  
✅ **Fixed:** Manual sync no longer creates duplicates  
✅ **Fixed:** Existing people are linked instead of duplicated  
✅ **Result:** Sync can be run multiple times safely  

**Next step:** Use `DeduplicatePeopleView` to clean existing duplicates, then replace your "Sync Now" button with `ContactsSyncView`.
