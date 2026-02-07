# Permission Dialog at Startup Fix

## Problem
The Contacts permission system dialog was appearing at app startup, before the user had a chance to go through the Settings → Permissions flow. This created a confusing experience where users were prompted for permissions without context.

## Root Cause
In `PersonDetailView.swift`, the `ContactPhotoFetcher.fetchThumbnailSync()` method was creating a **new CNContactStore instance** on every photo fetch:

```swift
let store = CNContactStore()  // ❌ Creates new store, can trigger permission dialog
```

Even though the code checked authorization status first, creating a new store instance could trigger the system permission dialog.

## Solution
Changed `ContactPhotoFetcher.fetchThumbnailSync()` to use the **shared CNContactStore** from `ContactsImportCoordinator`:

```swift
// Use the shared store to avoid triggering duplicate permission dialogs
let store = ContactsImportCoordinator.contactStore  // ✅ Uses singleton
```

## Why This Works

### The Problem with Multiple Store Instances
Creating new `CNContactStore()` instances can trigger permission dialogs because:
1. Each new store instance checks authorization state
2. The first access to a new store can trigger the system dialog
3. This happens even if you check `authorizationStatus` first

### The Solution: Singleton Pattern
Using a shared store instance:
1. **One point of permission request** - Only `ContactsImportCoordinator` creates the store
2. **No unexpected dialogs** - Background operations use the existing store
3. **Consistent state** - All parts of the app see the same authorization state
4. **Follows best practices** - Apple recommends using a single shared store instance

## Changed Files

### PersonDetailView.swift
**Line 267** - `fetchThumbnailSync()` method:
- **Before:** `let store = CNContactStore()`
- **After:** `let store = ContactsImportCoordinator.contactStore`

Also cleaned up redundant store references:
- Removed duplicate `sharedStore` variable on line 275
- Now uses single `store` variable consistently throughout method

## Permission Flow Now

### Correct Flow (After Fix)
1. **App launches** - No permission dialogs
2. **User navigates to Settings → Permissions**
3. **User clicks "Request Contacts Access"** button
4. **System permission dialog appears** (expected)
5. **User grants permission**
6. **ContactsImportCoordinator starts using the shared store**
7. **Photo fetching works** using the same shared store (no dialogs)

### What Was Happening (Before Fix)
1. **App launches**
2. **PersonDetailView loads** and tries to fetch contact photo
3. **New CNContactStore() created** 
4. **System permission dialog appears** ❌ (unexpected, no context)
5. User confused about why permissions are being requested

## Related Components

### ContactsImportCoordinator
- **Owns the shared CNContactStore instance**
- Created once at coordinator initialization
- Accessed via `ContactsImportCoordinator.contactStore`

### PermissionsManager
- **Owns the authorization flow**
- Uses its own store for permission requests
- Coordinates with ContactsImportCoordinator after permissions granted

### ContactValidator
- **Uses shared store for validation**
- Already correctly accepts store as parameter
- No changes needed

### MeIdentityManager
- **Already takes store as parameter**
- No changes needed

## Testing

### Verify Fix
1. **Reset permissions** in System Settings → Privacy & Security → Contacts → Remove SAM
2. **Quit and relaunch SAM**
3. **Verify NO permission dialog appears** on launch
4. **Navigate to Awareness or Inbox** (triggers PersonDetailView)
5. **Verify NO permission dialog appears** when viewing people
6. **Go to Settings → Permissions**
7. **Click "Request Contacts Access"**
8. **Verify permission dialog DOES appear** (expected)
9. **Grant permission**
10. **Go back to Awareness/Inbox**
11. **Verify contact photos load** without additional dialogs

### Success Criteria
✅ No permission dialogs at app startup  
✅ No permission dialogs when viewing person details  
✅ Permission dialog only appears when explicitly requested in Settings  
✅ Photos load correctly after permission granted  
✅ No duplicate permission requests  

## Best Practices Applied

1. **Single Store Instance** - Use one shared CNContactStore throughout the app
2. **Centralized Permission Management** - All permission requests go through PermissionsManager
3. **Lazy Access** - Don't touch Contacts APIs until user explicitly grants permission
4. **Graceful Degradation** - Check authorization status before any Contacts operation
5. **Coordinator Pattern** - ContactsImportCoordinator owns the store lifecycle

## Additional Notes

- This fix complements the Settings permission flow improvements
- All permission requests now route through Settings → Permissions tab
- Users have full context before being asked for permissions
- No "surprise" permission dialogs during normal app usage
