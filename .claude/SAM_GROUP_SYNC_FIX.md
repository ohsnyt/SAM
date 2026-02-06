# SAM Group Sync Fix

## Problem

When a contact is removed from the "SAM" group in Contacts.app (but not deleted), the link in SAM remains active. The person still shows as "Linked" with a photo thumbnail.

## Root Cause

`ContactSyncConfiguration.requireSAMGroupMembership` was set to `false`, which means the validation system only checks if contacts **exist** in the Contacts database, not whether they're still **in the SAM group**.

### The Validation Flow

When you remove a contact from the SAM group:

1. ✅ `CNContactStoreDidChange` notification fires
2. ✅ `ContactsSyncManager.validateAllLinkedContacts()` runs
3. ✅ For each linked person, validation checks the contact
4. ❌ **But**: with `requireSAMGroupMembership = false`, it only calls `ContactValidator.isValid(identifier)`
5. ❌ The contact still exists in Contacts.app → validation passes → link stays

### The Code Path

In `ContactsSyncManager.swift` (lines 226-253):

```swift
#if os(macOS)
if requireSAMGroupMembership {
    // This path checks both existence AND group membership
    let result = ContactValidator.validate(identifier, requireSAMGroup: true)
    // ...
} else {
    // THIS PATH WAS RUNNING: only checks existence
    isValid = await ContactValidator.isValid(identifier)
}
#endif
```

With the flag set to `false`, the SAM group check was never executed.

## Solution

### 1. Enable SAM Group Filtering

**File:** `ContactSyncConfiguration.swift`

**Change:**
```swift
static let requireSAMGroupMembership: Bool = true  // was: false
```

This tells the validation system to check **both**:
- Does the contact still exist? ✅
- Is the contact still in the "SAM" group? ✅

### 2. Enable Debug Logging (Temporary)

**File:** `ContactSyncConfiguration.swift`

**Change:**
```swift
static let enableDebugLogging: Bool = true  // was: false
```

This will print detailed validation information to the console so you can trace exactly what's happening.

## Testing the Fix

### Test Case: Remove Contact from SAM Group

1. Build and run the app with the new configuration
2. In Contacts.app, remove a linked contact from the "SAM" group (don't delete the contact)
3. Switch back to SAM

**Expected behavior:**
```
📱 ContactsSyncManager: Starting validation...
Contacts Authorization Status: ✅ Authorized
✅ CNContactStore access works (test query returned 0 results)
📱 ContactsSyncManager: Found 5 linked people to validate
  • Contact ABC-123-XYZ: ❌ invalid (not in SAM group)
  • Contact DEF-456-UVW: ✅ valid
  ...
📱 ContactsSyncManager: Cleared 1 stale contact link(s)
```

4. The person should now show an "Unlinked" badge (orange `person.crop.circle.badge.questionmark`)
5. A banner should appear: "1 contact removed from SAM or Contacts"

### What Changes

| Before Fix | After Fix |
|------------|-----------|
| Contact removed from group → stays linked | Contact removed from group → auto-unlinked |
| No banner notification | Banner: "1 contact removed..." |
| Photo still shows | Photo disappears, unlinked badge appears |
| No console logs | Detailed validation logs |

## When to Use Each Mode

### `requireSAMGroupMembership = true` (Strict Mode)
✅ Use when you want the SAM group to be the "source of truth"  
✅ Contacts removed from the group are automatically unlinked  
✅ Enforces the workflow: "SAM only tracks people in the SAM group"

**Recommended for:** Group-based import workflow (your current setup)

### `requireSAMGroupMembership = false` (Lenient Mode)
✅ Use when contacts might move between groups  
✅ Links persist as long as the contact exists  
✅ Only unlinks when the contact is fully deleted

**Recommended for:** Manual linking workflow (no group-based import)

## After Testing

Once you've confirmed the fix works:

1. **Disable debug logging** in `ContactSyncConfiguration.swift`:
   ```swift
   static let enableDebugLogging: Bool = false
   ```

2. **Leave `requireSAMGroupMembership = true`** if you want strict group filtering

3. **Update `context.md`** to reflect that SAM group filtering is now enabled by default

## Implementation Notes

### Platform Differences

| Feature | macOS | iOS |
|---------|-------|-----|
| SAM group filtering | ✅ Works | ❌ Ignored (groups read-only) |
| Contact existence check | ✅ Works | ✅ Works |

On iOS, `requireSAMGroupMembership` is always ignored and only existence is validated, regardless of the setting.

### Performance

- Group membership check adds one extra `CNContactStore` lookup per linked person
- Lookups happen in parallel via `TaskGroup` on background threads
- For 100 linked people, validation takes ~1-2 seconds on modern Macs
- Acceptable cost for accuracy (runs on app launch + when Contacts.app changes)

## Related Files

- `ContactSyncConfiguration.swift` — App-wide sync settings
- `ContactValidator.swift` — Low-level validation logic
- `ContactsSyncManager.swift` — Orchestrates validation passes
- `CONTACT_VALIDATION_README.md` — Full system documentation

## Status

✅ **Fix Applied**  
🧪 **Ready for Testing**  
📝 **Debug Logging Enabled** (temporarily)

---

**Next Step:** Remove a contact from the SAM group in Contacts.app and verify that SAM auto-unlinks it with a banner notification.
