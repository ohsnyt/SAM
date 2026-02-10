# ContactsImportCoordinator - Static Store Property Added

## Solution

Added a static computed property to `ContactsImportCoordinator` that exposes the shared `CNContactStore` from `PermissionsManager`:

```swift
@MainActor
final class ContactsImportCoordinator {
    static let shared = ContactsImportCoordinator()
    
    /// Expose the shared CNContactStore from PermissionsManager.
    /// All Contacts validation should use this instance to avoid duplicate permission requests.
    static var contactStore: CNContactStore {
        PermissionsManager.shared.contactStore
    }
    
    // ... rest of class
}
```

## Why This Works

Your architecture has:
- `PermissionsManager.shared` holds the actual `CNContactStore`
- `ContactsImportCoordinator` uses `permissions.contactStore` internally
- We expose it statically so `ContactValidator` and `ContactsSyncManager` can access it

This maintains your existing architecture while providing the static access point needed for the ContactValidator pattern.

## Benefits

1. **No duplicate permission requests** - All code uses the same store instance
2. **Matches CalendarImportCoordinator pattern** - Similar to `CalendarImportCoordinator.eventStore`
3. **No architecture changes** - Just exposes what's already there
4. **Clean API** - `ContactsImportCoordinator.contactStore` is clear and consistent

## What This Enables

Now all the ContactValidator fixes will work:

```swift
// In ContactsSyncManager, ContactValidator, etc.:
let contactStore = ContactsImportCoordinator.contactStore
ContactValidator.isValid(identifier, using: contactStore)
ContactValidator.validate(identifier, requireSAMGroup: true, using: contactStore)
```

## Remaining Steps

You still need to apply the ContactValidator signature updates to the duplicate files in subdirectories:

1. **SAM_crm/Syncs/ContactsSyncManager.swift** 
   - Update to use `ContactsImportCoordinator.contactStore`
   - Update ContactValidator calls with `using:` parameter

2. **SAM_crm/Syncs/ContactValidationExamples.swift**
   - Update ContactValidator calls with `using:` parameter

Or if these are true duplicates, just delete them and keep only the fixed versions in `/repo/`.

## Testing

After this change + updating the duplicate files:
1. Clean build (⇧⌘K)
2. Delete app from Applications
3. Build and run (⌘R)
4. You should see only ONE Contacts permission dialog
5. Swift 6 warnings about ContactValidator should be resolved

## Next: Apply to Duplicate Files

Use the same find/replace pattern in the subdirectory files:

**Find:**
```swift
ContactValidator.isValid(identifier)
```

**Replace:**
```swift
let contactStore = ContactsImportCoordinator.contactStore
ContactValidator.isValid(identifier, using: contactStore)
```

**Find:**
```swift
ContactValidator.validate(identifier, requireSAMGroup: true)
```

**Replace:**
```swift
let contactStore = ContactsImportCoordinator.contactStore
ContactValidator.validate(identifier, requireSAMGroup: true, using: contactStore)
```
