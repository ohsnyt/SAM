# Contact Validation & Sync System

This implementation ensures that SAM's contact links stay synchronized with the system Contacts database. When a contact is deleted from Contacts.app or removed from the SAM group, the link is automatically cleared in SAM.

## Architecture

### 1. **ContactValidator** (Stateless Utility)
Low-level validation functions that check:
- ✅ Contact existence (is the contact still in the Contacts database?)
- ✅ SAM group membership (is the contact still in the "SAM" group?) — macOS only
- ✅ Combined validation with granular failure reasons

**Key Methods:**
```swift
ContactValidator.isValid(_ identifier: String) -> Bool
ContactValidator.isInSAMGroup(_ identifier: String) -> Bool
ContactValidator.validate(_ identifier: String, requireSAMGroup: Bool) -> ValidationResult
```

### 2. **ContactsSyncManager** (@Observable, @MainActor)
Manages the lifecycle of contact validation:
- 🔔 Observes `CNContactStoreDidChange` notifications
- 🔄 Automatically validates all linked contacts when changes occur
- 🧹 Clears stale `contactIdentifier` values from `SamPerson` records
- 📊 Exposes `lastClearedCount` for UI notifications

**Lifecycle:**
```swift
// Start observing (typically in PeopleListView or AppShellView)
contactsSyncManager.startObserving(modelContext: modelContext)

// Automatically validates on Contacts changes
// Also runs an initial validation on startup

// Stops automatically on deinit
```

**Configuration:**
```swift
// Default: only check that contacts exist
contactsSyncManager.requireSAMGroupMembership = false

// Strict mode (macOS only): require SAM group membership
contactsSyncManager.requireSAMGroupMembership = true
```

### 3. **ContactSyncStatusView** (UI Component)
A dismissible banner that appears when contacts are auto-unlinked:
- Shows count of cleared links
- Auto-dismisses after 5 seconds
- Can be manually dismissed

### 4. **Integration Points**

#### **PeopleListView**
- Instantiates `ContactsSyncManager` as `@State`
- Starts observing when the view appears
- Shows `ContactSyncStatusView` when links are cleared

#### **PersonDetailView**
- Validates contact on every navigation (via `.task(id: person.id)`)
- Skips photo fetch if contact is invalid
- Sets `contactWasInvalidated` flag for future UI enhancements

#### **ContactPhotoFetcher**
- Validates contact before attempting to fetch thumbnail
- Avoids wasted I/O for deleted contacts

## How It Works

### Automatic Validation (Background)
1. User deletes a contact in Contacts.app
2. `CNContactStoreDidChange` notification fires
3. `ContactsSyncManager.validateAllLinkedContacts()` runs
4. Each `SamPerson.contactIdentifier` is validated on a background thread
5. Invalid identifiers are set to `nil` on the main actor
6. SwiftData context is saved
7. UI updates (person shows "Unlinked" badge again)
8. Banner notification appears

### Manual Validation (Per-Person)
1. User navigates to a person detail view
2. `PersonDetailView.task(id:)` runs
3. `validateAndFetchPhoto()` checks if contact still exists
4. If invalid, photo is not fetched and flag is set
5. UI can show inline warning or auto-trigger re-link flow

## Performance

- **Validation is off the main thread**: All `CNContactStore` I/O happens in `Task.detached` blocks
- **Batch processing**: `validateAllLinkedContacts()` pulls all identifiers, validates in parallel, then updates SwiftData in one pass
- **Efficient queries**: Uses `FetchDescriptor` with predicate to only fetch people with `contactIdentifier != nil`

## Platform Differences

| Feature | macOS | iOS |
|---------|-------|-----|
| Contact existence validation | ✅ | ✅ |
| SAM group membership checking | ✅ | ❌ (groups are read-only) |
| `CNContactStoreDidChange` notifications | ✅ | ✅ |

On iOS, setting `requireSAMGroupMembership = true` is ignored; only existence is validated.

## Testing

### Test Case 1: Delete Contact from Contacts.app
1. Link a person to a contact
2. Open Contacts.app and delete that contact
3. Return to SAM
4. **Expected:** Banner appears, person shows "Unlinked" badge

### Test Case 2: Remove Contact from SAM Group (macOS)
1. Enable `requireSAMGroupMembership = true`
2. Link a person to a contact in the SAM group
3. Open Contacts.app and remove the contact from SAM group (keep contact in database)
4. Return to SAM
5. **Expected:** Banner appears, person shows "Unlinked" badge

### Test Case 3: Navigate to Detail View with Deleted Contact
1. Link a person to a contact
2. Delete the contact in Contacts.app
3. Navigate to the person's detail view (before background sync runs)
4. **Expected:** No photo appears, validation prevents the lookup

### Test Case 4: Multiple Deletions
1. Link 5 people to contacts
2. Delete all 5 contacts in Contacts.app
3. Return to SAM
4. **Expected:** Banner shows "5 contacts removed from SAM or Contacts"

## Future Enhancements

### 1. Inline Warnings
When `contactWasInvalidated` is true in `PersonDetailView`, show an inline banner:
```swift
if contactWasInvalidated {
    InfoBox("This person's contact was deleted. Would you like to re-link?") {
        Button("Re-Link") { /* open LinkContactSheet */ }
    }
}
```

### 2. Smart Re-Linking
If a contact is deleted but a new contact with the same email is created, auto-suggest re-linking.

### 3. Undo Support
When auto-unlinking happens, provide an undo action in the banner (in case the user temporarily removed a contact from the SAM group by mistake).

### 4. Audit Log
Track when contacts are unlinked, who they were, and why (deleted vs. removed from group) for compliance and debugging.

### 5. Conflict Resolution
If `requireSAMGroupMembership` is enabled and a contact is removed from the SAM group but not deleted:
- Show a different message ("Contact removed from SAM group")
- Offer to add it back to the group instead of unlinking

## Files Created

- `ContactValidator.swift` — Stateless validation functions
- `ContactsSyncManager.swift` — Observable sync coordinator
- `ContactSyncStatusView.swift` — UI notification banner

## Files Modified

- `PersonDetailView.swift` — Added validation in `.task`, updated `ContactPhotoFetcher`
- `PeopleListView.swift` — Integrated `ContactsSyncManager`, added banner UI

## Dependencies

- `Contacts.framework` (system)
- `SwiftData` (for `ModelContext`, `@Query`, `FetchDescriptor`)
- `SwiftUI` (for `@Observable`, `@State`, `.task`)

## Configuration

No configuration is required. The system works out-of-the-box with sensible defaults:
- Validates on app launch
- Observes Contacts changes automatically
- Only checks contact existence (not SAM group membership)

To enable SAM group filtering on macOS:
```swift
// In PeopleListView or AppShellView
contactsSyncManager.requireSAMGroupMembership = true
```

---

**Status:** ✅ Implementation Complete  
**Tested:** 🧪 Manual testing required  
**Platform:** macOS (primary), iOS (partial — no group filtering)
