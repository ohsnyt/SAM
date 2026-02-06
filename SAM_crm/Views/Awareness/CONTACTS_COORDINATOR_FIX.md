# ContactsImportCoordinator Store Access Fix

## Problem

The fix I provided assumes `ContactsImportCoordinator.contactStore` exists as a static property, but it doesn't. We need to pass the store instance through properly.

## Solution Options

### Option 1: Add Static Property to ContactsImportCoordinator (Recommended)

In `ContactsImportCoordinator.swift`, add a static property similar to how `CalendarImportCoordinator` has `eventStore`:

```swift
final class ContactsImportCoordinator {
    /// Single shared CNContactStore for the entire app.
    /// All Contacts access should use this instance to avoid duplicate permission requests.
    static let contactStore = CNContactStore()
    
    // Rest of the class...
}
```

This follows the same pattern as `CalendarImportCoordinator.eventStore` mentioned in your context.md.

### Option 2: Pass Store Through ContactsSyncManager Init

If you don't want a static property, pass the store through the sync manager:

```swift
// In ContactsSyncManager.swift
@MainActor
@Observable
final class ContactsSyncManager {
    private let contactStore: CNContactStore
    
    init(contactStore: CNContactStore, modelContext: ModelContext?) {
        self.contactStore = contactStore
        self.modelContext = modelContext
        // ... rest of init
    }
    
    // Then use self.contactStore instead of ContactsImportCoordinator.contactStore
}
```

## Recommended Fix (Option 1)

### Step 1: Update ContactsImportCoordinator

Find `ContactsImportCoordinator.swift` and add at the top of the class:

```swift
final class ContactsImportCoordinator: ObservableObject {
    /// Single shared CNContactStore for the entire app.
    /// Prevents duplicate permission requests and ensures consistent change tracking.
    static let contactStore = CNContactStore()
    
    // Change any instance property to use the static:
    // Before: private let contactStore = CNContactStore()
    // After: private let contactStore = Self.contactStore
```

### Step 2: Update Duplicate Files

The errors are coming from files in subdirectories. You need to apply the fixes to:

**Files that need updating:**
1. `SAM_crm/Syncs/ContactsSyncManager.swift` - Apply our ContactValidator fixes
2. `SAM_crm/Syncs/ContactValidationExamples.swift` - Update ContactValidator calls

**What to change in these files:**

```swift
// Find all instances of:
ContactValidator.isValid(identifier)
ContactValidator.validate(identifier, requireSAMGroup: true)

// Replace with:
let contactStore = ContactsImportCoordinator.contactStore
ContactValidator.isValid(identifier, using: contactStore)
ContactValidator.validate(identifier, requireSAMGroup: true, using: contactStore)
```

### Step 3: Remove Async from Sync Code

The errors about "No 'async' operations occur within 'await' expression" mean you have `await` on synchronous code.

**In ContactsSyncManager and ContactValidationExamples, find:**

```swift
// Wrong:
await Task.detached { ... }.value

// Should be:
Task.detached { ... }.value  // No await needed
```

Or if the block needs to be async:

```swift
await Task.detached {
    // Only use await here if you have actual async operations inside
}.value
```

## Quick Fix for Compile

Since you're testing, here's the fastest path:

### 1. Check if ContactsImportCoordinator has an instance

If it's an instance-based coordinator, you might need to store a reference:

```swift
// In your app setup (SAM_crmApp or similar):
let contactsCoordinator = ContactsImportCoordinator(...)
let syncManager = ContactsSyncManager(
    contactStore: contactsCoordinator.contactStore,  // Pass instance store
    modelContext: modelContext
)
```

### 2. Or make it static (cleanest)

Add to ContactsImportCoordinator:

```swift
static let contactStore = CNContactStore()
```

Then rebuild.

## File Locations to Update

Based on error messages, these files exist and need fixes:

1. **SAM_crm/Syncs/ContactsSyncManager.swift** (lines 226, 276, 387)
   - Add `ContactsImportCoordinator.contactStore` references
   - Update ContactValidator calls with `using:` parameter

2. **SAM_crm/Syncs/ContactValidationExamples.swift** (lines 65, 233)
   - Update ContactValidator calls with `using:` parameter
   - Add `contactStore` references

## Testing After Fix

1. Make sure only ONE `CNContactStore` is created (the static one)
2. All ContactValidator calls should pass `using: contactStore`
3. No more duplicate permission requests
4. Swift 6 warnings should be reduced

## If You're Stuck

Share the contents of `ContactsImportCoordinator.swift` and I can provide an exact fix for how to make the store accessible.
