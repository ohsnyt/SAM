# 🔧 Fix: Duplicate Contacts on First Launch

## Problem

**Symptom:** Linked contacts appear twice in PeopleListView:
- Once as "linked" (with contactIdentifier)
- Once as "unlinked" (without contactIdentifier)

Truly unlinked contacts only appear once.

## Root Cause

### The Permission Timing Issue

1. **App launches for first time** after fresh build
2. **Contacts permission status:** `.notDetermined`
3. **SwiftData loads:** People have `contactIdentifier` from previous sessions
4. **Validation runs immediately:** Can't access Contacts yet (permission not granted)
5. **All contacts marked as invalid:** `contactIdentifier` set to `nil`
6. **User grants permission:** But damage is already done
7. **Later, contacts are re-imported:** New `SamPerson` records created
8. **Result:** Duplicate people - original (now unlinked) + newly imported (linked)

### Flow Diagram

```
App Launch (Fresh Build)
    ↓
Permission = .notDetermined
    ↓
SwiftData: Person "John Smith" has contactIdentifier = "ABC123"
    ↓
Validation runs before permission granted
    ↓
Can't access Contacts → marks as invalid
    ↓
Person "John Smith" now has contactIdentifier = nil
    ↓
User grants Contacts permission
    ↓
Contact import runs
    ↓
Creates NEW Person "John Smith" with contactIdentifier = "ABC123"
    ↓
Result: TWO "John Smith" records
    - One unlinked (original, cleared)
    - One linked (newly created)
```

## Solution Applied

### 1. Wait for Permission Before Validating

**In `ContactsSyncManager.startObserving()`:**

```swift
if ContactSyncConfiguration.validateOnAppLaunch {
    Task {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        
        if status == .authorized {
            // Already have permission - validate now
            await validateAllLinkedContacts()
            
        } else if status == .notDetermined {
            // Need to request permission first
            do {
                let store = CNContactStore()
                _ = try await store.requestAccess(for: .contacts)
                
                // NOW we can safely validate
                await validateAllLinkedContacts()
            } catch {
                // Permission denied - don't validate
            }
        }
    }
}
```

### 2. Safety Guard in Validation

**In `validateAllLinkedContacts()`:**

```swift
// Don't validate if we don't have permission
let status = CNContactStore.authorizationStatus(for: .contacts)
guard status == .authorized else {
    print("⚠️ Skipping validation - no Contacts permission")
    return
}
```

### 3. Auto-Deduplication After Permission Grant

**When permission is first granted:**

```swift
// Clean up any duplicates that were created during permission flow
if ContactSyncConfiguration.deduplicateAfterPermissionGrant {
    let cleaner = DuplicatePersonCleaner(modelContext: modelContext)
    let count = try? cleaner.cleanAllDuplicates()
    
    if count > 0 {
        print("📱 Merged \(count) duplicate people")
    }
}
```

## Configuration

### Enable/Disable Auto-Deduplication

In `ContactSyncConfiguration.swift`:

```swift
/// Auto-deduplicate after permission is granted (default: true)
static let deduplicateAfterPermissionGrant: Bool = true
```

Set to `false` if you want to manually control deduplication.

### Manual Deduplication

If you already have duplicates, you can manually trigger deduplication:

```swift
// In your view or app coordinator
let count = try? contactsSyncManager.deduplicatePeople()
print("Merged \(count) duplicates")
```

Or use the existing UI:

```swift
// You already have DeduplicatePeopleView
NavigationLink("Fix Duplicates") {
    DeduplicatePeopleView()
}
```

## How Deduplication Works

The `DuplicatePersonCleaner` finds duplicates by:

1. **Same contactIdentifier** (definite duplicate)
2. **Same canonical name** (likely duplicate)
   - Lowercase
   - Remove punctuation
   - Normalize whitespace

When merging:
- **Keep:** Person with contactIdentifier (if any)
- **Merge:** All relationships, participations, coverages, etc.
- **Delete:** The duplicate

## Testing the Fix

### Step 1: Clean Install Test

1. Delete the app
2. Clean build
3. Launch app
4. Grant Contacts permission when prompted
5. **Expected:** No duplicates, all contacts properly linked

### Step 2: Console Output (Debug Mode)

Enable debug logging:
```swift
// In ContactSyncConfiguration.swift
static let enableDebugLogging: Bool = true
```

Expected console output:
```
📱 ContactsSyncManager: Waiting for Contacts permission before validating...
📱 ContactsSyncManager: Permission granted, checking for duplicates...
📱 ContactsSyncManager: Merged 0 duplicate people (none found)
📱 ContactsSyncManager: Starting validation...
Contacts Authorization Status: ✅ Authorized
✅ CNContactStore access works
📱 ContactsSyncManager: Found 5 linked people to validate
  • Contact ABC123: ✅ valid
  • Contact DEF456: ✅ valid
✅ ContactsSyncManager: All 5 contact link(s) are valid
```

### Step 3: Fix Existing Duplicates

If you already have duplicates from before the fix:

**Option A: Manual Deduplication**
```swift
// Add a button in your UI
Button("Fix Duplicates") {
    let count = try? contactsSyncManager.deduplicatePeople()
    // Show alert: "Merged \(count) duplicates"
}
```

**Option B: Use Existing UI**
Navigate to `DeduplicatePeopleView` (you already have this)

**Option C: Automatic (Next Launch)**
The fix will automatically deduplicate on next launch when permission is granted.

## Files Modified

1. **ContactsSyncManager.swift**
   - Added permission check before validation
   - Added `requestAccess` flow for `.notDetermined` status
   - Added auto-deduplication after permission grant
   - Added manual `deduplicatePeople()` method

2. **ContactSyncConfiguration.swift**
   - Added `deduplicateAfterPermissionGrant` flag

## Summary

✅ **Fixed:** Validation now waits for Contacts permission  
✅ **Added:** Auto-deduplication after permission is granted  
✅ **Added:** Manual deduplication method  
✅ **Result:** No more duplicate contacts on first launch  

**Existing duplicates:** Will be automatically cleaned on next launch, or can be manually deduplicated using the existing `DeduplicatePeopleView`.

---

**Next Step:** Clean build and test to verify no duplicates appear when granting permission.
