# 🔍 Debugging: All Contacts Showing as Unlinked

## Quick Diagnosis Steps

### Step 1: Enable Debug Logging

In `ContactSyncConfiguration.swift`, set:

```swift
static let enableDebugLogging: Bool = true
static let dryRunMode: Bool = true  // Won't clear links, just logs
```

### Step 2: Restart the App

Watch the console output. You should see something like:

**Good output (permission granted):**
```
📱 ContactsSyncManager: Starting validation...
Contacts Authorization Status: ✅ Authorized
✅ CNContactStore access works
📱 ContactsSyncManager: Found 5 linked people to validate
  • Contact ABC123-456DEF: ✅ valid
  • Contact GHI789-012JKL: ✅ valid
✅ ContactsSyncManager: All 5 contact link(s) are valid
```

**Bad output (permission issue):**
```
⚠️ ContactsSyncManager: Skipping validation - Contacts permission not granted (status: 0)
```

**Bad output (validation failing):**
```
📱 ContactsSyncManager: Starting validation...
Contacts Authorization Status: ✅ Authorized
✅ CNContactStore access works
📱 ContactsSyncManager: Found 5 linked people to validate
  • Contact ABC123-456DEF: ❌ invalid
⚠️ ContactValidator.isValid(ABC123-456DEF): The operation couldn't be completed. (CNErrorDomain error 200.)
  • Contact GHI789-012JKL: ❌ invalid
🔸 DRY RUN: Would clear 2 stale contact link(s) (not saving)
```

---

## Common Issues & Solutions

### Issue 1: Permission Not Granted

**Console shows:**
```
⚠️ Skipping validation - Contacts permission not granted (status: 0)
```

**Solution:**
1. Check System Settings > Privacy & Security > Contacts
2. Verify SAM has permission
3. If not, grant permission and restart

### Issue 2: All Contacts Marked as Invalid

**Console shows all contacts as `❌ invalid`**

**Possible causes:**
1. Contact identifiers in SwiftData are invalid/corrupted
2. Contact identifiers from a different device/backup
3. Contacts were actually deleted

**Solution:**
Check a specific contact manually:

```swift
// In ContactValidationDebugView or a test
let testIdentifier = "ABC123-456DEF"  // From your SwiftData
let isValid = ContactValidator.isValid(testIdentifier)
print("Contact \(testIdentifier) is valid: \(isValid)")

// Also check what's in Contacts.app
let store = CNContactStore()
do {
    let contact = try store.unifiedContact(withIdentifier: testIdentifier, keysToFetch: [])
    print("✅ Contact found: \(contact.identifier)")
} catch {
    print("❌ Contact not found: \(error)")
}
```

### Issue 3: validateOnAppLaunch is Disabled

**Console shows nothing**

**Check:**
```swift
// In ContactSyncConfiguration.swift
static let validateOnAppLaunch: Bool = true  // Should be true
```

### Issue 4: Contacts Were Re-Imported with Different Identifiers

If you restored from a backup or migrated devices, the `contactIdentifier` values in SwiftData might not match the current Contacts database.

**Solution:**
Manually re-link contacts, or use a script to refresh links:

```swift
// Pseudo-code for refreshing links by email
for person in people where person.contactIdentifier == nil && person.email != nil {
    // Search Contacts by email
    let predicate = CNContact.predicateForContacts(matchingEmailAddress: person.email!)
    if let match = try? store.unifiedContacts(matching: predicate, keysToFetch: []).first {
        person.contactIdentifier = match.identifier
    }
}
try modelContext.save()
```

---

## What to Look For in Console

### 1. Permission Status

```
Contacts Authorization Status: ✅ Authorized  // ← Should see this
```

If you see `❓ Not Determined` or `❌ Denied`, fix permissions first.

### 2. Store Access Test

```
✅ CNContactStore access works (test query returned X results)
```

If this fails, there's a fundamental access issue.

### 3. Validation Results

```
  • Contact ABC123: ✅ valid  // ← Should see this for real contacts
  • Contact XYZ789: ❌ invalid  // ← Only for deleted contacts
```

If ALL contacts show `❌ invalid`, the identifiers in SwiftData don't match Contacts.app.

### 4. Detailed Errors

```
⚠️ ContactValidator.isValid(ABC123): The operation couldn't be completed. (CNErrorDomain error 200.)
```

Error 200 = contact not found. This means the identifier in SwiftData is invalid.

---

## Next Steps Based on Console Output

### If permission is the issue:
1. Grant Contacts permission
2. Restart app
3. Validation should pass

### If all contacts are marked invalid:
The contact identifiers in SwiftData don't match what's in Contacts.app.

**Quick fix:**
1. Set `dryRunMode = false` (stop dry run)
2. Set `validateOnAppLaunch = false` (stop auto-validation)
3. Manually re-link contacts using the UI
4. Or, write a script to refresh links by email/name

### If only some contacts are invalid:
Those contacts were actually deleted. The validation is working correctly.

---

## Testing Individual Contacts

Use `ContactValidationDebugView`:

1. Add to your app (already created)
2. Navigate to it
3. Tap "Run Diagnostics" → See permission status
4. Tap "Test All Contacts" → See which are valid/invalid
5. Check the raw identifiers at the bottom

---

## Quick Fix for Testing

**Temporarily disable validation:**

```swift
// In ContactSyncConfiguration.swift
static let validateOnAppLaunch: Bool = false  // ← Disable
```

This lets you manually control when validation runs, so you can:
1. Check current state
2. Manually re-link contacts
3. Then re-enable validation once links are correct

---

## Share Console Output

If you're still stuck, enable debug logging and share the console output. Look for:
- Permission status
- How many contacts are being validated
- How many are marked as invalid
- Any error messages with details
