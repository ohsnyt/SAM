# Quick Start: Contact Validation

This guide shows you how to use the contact validation system in SAM.

---

## ✅ Already Integrated

The system is **already working** in `PeopleListView`. No additional setup required!

When you:
1. Delete a contact from Contacts.app
2. Remove a contact from the SAM group (macOS)

SAM will automatically:
- Detect the change
- Clear the stale `contactIdentifier`
- Show the person as "Unlinked" again
- Display a banner notification

---

## 🎛️ Configuration (Optional)

All settings are in **`ContactSyncConfiguration.swift`**:

### Enable SAM Group Filtering (macOS only)
```swift
// In ContactSyncConfiguration.swift
static let requireSAMGroupMembership: Bool = true  // ← Change to true
```

Now contacts must be in the "SAM" group to stay linked.

### Adjust Banner Display Time
```swift
// In ContactSyncConfiguration.swift
static let bannerAutoDismissDelay: TimeInterval = 10.0  // ← Change to 10 seconds
```

### Enable Debug Logging
```swift
// In ContactSyncConfiguration.swift
static let enableDebugLogging: Bool = true  // ← Change to true
```

You'll see console output like:
```
✅ ContactsSyncManager: All 47 contact link(s) are valid
📱 ContactsSyncManager: Cleared 2 stale contact link(s)
```

---

## 🔧 Using Modifiers (Alternative Integration)

If you want to add validation to other views, use the convenience modifiers:

### Option 1: Monitor contacts anywhere
```swift
YourView()
    .monitorContactChanges(modelContext: modelContext)
```

This adds:
- Automatic validation on Contacts changes
- Banner notification when links are cleared

### Option 2: Validate a specific person
```swift
PersonDetailView(person: person)
    .validateContactOnAppear(person: person, modelContext: modelContext)
```

This validates only that person when the view appears.

---

## 🧪 Manual Testing

### Test 1: Delete a Contact
1. Open SAM, link a person to a contact
2. Open Contacts.app
3. Delete that contact
4. Return to SAM
5. **Expected:** Banner appears, person shows "Unlinked" badge

### Test 2: Remove from SAM Group (macOS)
1. Set `requireSAMGroupMembership = true`
2. Link a person to a contact in the SAM group
3. Open Contacts.app
4. Remove the contact from SAM group (don't delete it)
5. Return to SAM
6. **Expected:** Banner appears, person shows "Unlinked" badge

### Test 3: Navigate to Invalid Contact
1. Link a person to a contact
2. Delete the contact in Contacts.app
3. Navigate to that person's detail view
4. **Expected:** No photo, no crash

---

## 📚 Advanced Usage

### Get the ContactsSyncManager directly
```swift
@State private var contactsSyncManager = ContactsSyncManager()

// In .task or .onAppear:
contactsSyncManager.startObserving(modelContext: modelContext)

// Check if a specific person's contact is valid:
let wasCleared = await contactsSyncManager.validatePerson(person)
if wasCleared {
    print("Contact was invalid and link was cleared")
}

// Access the last cleared count:
let count = contactsSyncManager.lastClearedCount

// Check if validation is running:
let isValidating = contactsSyncManager.isValidating
```

### Validate a contact without linking to SwiftData
```swift
// Just check if a contact exists:
let exists = ContactValidator.isValid("ABC123-CONTACT-ID")

// Check if in SAM group (macOS only):
let inGroup = ContactValidator.isInSAMGroup("ABC123-CONTACT-ID")

// Full validation with reason:
let result = ContactValidator.validate("ABC123-CONTACT-ID", requireSAMGroup: true)

switch result {
case .valid:
    print("Contact is valid")
case .contactDeleted:
    print("Contact was deleted")
case .notInSAMGroup:
    print("Contact exists but not in SAM group")
case .accessDenied:
    print("Contacts permission not granted")
}
```

---

## 🚨 Troubleshooting

### Banner doesn't appear when I delete a contact
**Check:**
1. Is Contacts permission granted?
2. Is the contact actually linked (has `contactIdentifier`)?
3. Is debug logging enabled? Check the console.
4. Did you delete the contact while SAM was running?

### Validation seems slow
**Solution:**
- Validation runs on background threads, but CNContactStore I/O can be slow for large contact lists
- Consider disabling `validateOnAppLaunch` if you have thousands of contacts
- Enable debug logging to see how long validation takes

### SAM group filtering doesn't work (macOS)
**Check:**
1. Is `requireSAMGroupMembership = true` in `ContactSyncConfiguration`?
2. Does the "SAM" group exist in Contacts.app?
3. Is the contact you're testing actually in the SAM group?

### iOS doesn't filter by SAM group
**Expected behavior:**
- iOS doesn't support group filtering (groups are read-only)
- Only contact existence is validated on iOS
- `requireSAMGroupMembership` is ignored on iOS

---

## 📖 More Information

See these files for details:
- `IMPLEMENTATION_SUMMARY.md` — What was implemented and how
- `CONTACT_VALIDATION_README.md` — Full technical documentation

---

**Status:** ✅ Production Ready  
**Platform:** macOS (full), iOS (existence validation only)  
**Performance:** Optimized for large contact lists
