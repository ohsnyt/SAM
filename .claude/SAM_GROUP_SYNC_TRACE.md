# SAM Group Sync - Visual Trace

## The Problem (Before Fix)

```
┌─────────────────────────────────────────────────────────────┐
│ User removes "John Smith" from SAM group in Contacts.app   │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ CNContactStoreDidChange notification fires                  │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ ContactsSyncManager.validateAllLinkedContacts() runs        │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ Check: requireSAMGroupMembership = false                    │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ Only runs: ContactValidator.isValid(identifier)             │
│ (checks if contact exists, ignores group membership)        │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ Contact "John Smith" still exists in Contacts.app ✅        │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ Validation PASSES → link stays → person still shows as      │
│ "Linked" with photo thumbnail ❌ WRONG                      │
└─────────────────────────────────────────────────────────────┘
```

---

## The Solution (After Fix)

```
┌─────────────────────────────────────────────────────────────┐
│ User removes "John Smith" from SAM group in Contacts.app   │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ CNContactStoreDidChange notification fires                  │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ ContactsSyncManager.validateAllLinkedContacts() runs        │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ Check: requireSAMGroupMembership = true ✅                  │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ Runs: ContactValidator.validate(identifier,                 │
│                                 requireSAMGroup: true)       │
│ (checks BOTH existence AND group membership)                │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ 1. Does contact exist? YES ✅                               │
│ 2. Is contact in SAM group? NO ❌                           │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ Validation FAILS → set contactIdentifier = nil              │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ modelContext.save()                                         │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ UI updates:                                                 │
│  • Person shows "Unlinked" badge (orange icon)              │
│  • Photo thumbnail disappears                               │
│  • Banner: "1 contact removed from SAM or Contacts"         │
└─────────────────────────────────────────────────────────────┘
```

---

## Code Path Comparison

### Before Fix (Lenient Mode)
```swift
// ContactsSyncManager.swift, line 226-253

#if os(macOS)
if requireSAMGroupMembership {  // ← THIS WAS FALSE
    // Strict path: check both existence AND group
    let result = ContactValidator.validate(identifier, requireSAMGroup: true)
    // ...
} else {
    // ← THIS PATH RAN: only check existence
    isValid = await ContactValidator.isValid(identifier)
}
#endif
```

### After Fix (Strict Mode)
```swift
// ContactsSyncManager.swift, line 226-253

#if os(macOS)
if requireSAMGroupMembership {  // ← NOW TRUE ✅
    // ← THIS PATH RUNS: check both existence AND group
    let result = ContactValidator.validate(identifier, requireSAMGroup: true)
    switch result {
    case .valid:
        return true
    case .notInSAMGroup:  // ← NOW CATCHES THIS CASE
        return false
    case .contactDeleted:
        return false
    case .accessDenied:
        return false
    }
} else {
    // Lenient path (not used anymore)
    isValid = await ContactValidator.isValid(identifier)
}
#endif
```

---

## ContactValidator Logic

### `isValid(identifier)` - Lenient Check
```swift
static func isValid(_ identifier: String) -> Bool {
    let store = CNContactStore()
    do {
        let keys = [CNContactIdentifierKey as CNKeyDescriptor]
        _ = try store.unifiedContact(withIdentifier: identifier, keysToFetch: keys)
        return true  // Contact exists ✅
    } catch {
        return false  // Contact deleted ❌
    }
}
```

### `validate(identifier, requireSAMGroup: true)` - Strict Check
```swift
static func validate(_ identifier: String, requireSAMGroup: Bool) -> ValidationResult {
    // Step 1: Check existence
    guard isValid(identifier) else {
        return .contactDeleted
    }
    
    // Step 2: Check group membership (macOS only)
    #if os(macOS)
    if requireSAMGroup && !isInSAMGroup(identifier) {
        return .notInSAMGroup  // ← THIS IS THE KEY CHECK
    }
    #endif
    
    return .valid
}
```

### `isInSAMGroup(identifier)` - Group Membership Check
```swift
static func isInSAMGroup(_ identifier: String) -> Bool {
    let store = CNContactStore()
    do {
        // 1. Find the "SAM" group
        let allGroups = try store.groups(matching: nil)
        guard let samGroup = allGroups.first(where: { $0.name == "SAM" }) else {
            return false  // SAM group doesn't exist
        }
        
        // 2. Fetch all contacts in the SAM group
        let predicate = CNContact.predicateForContactsInGroup(withIdentifier: samGroup.identifier)
        let contactsInGroup = try store.unifiedContacts(
            matching: predicate,
            keysToFetch: [CNContactIdentifierKey]
        )
        
        // 3. Check if our contact is in the list
        return contactsInGroup.contains { $0.identifier == identifier }
        
    } catch {
        return false
    }
}
```

---

## Debug Console Output

### When Contact Removed from SAM Group

```
📱 ContactsSyncManager: Starting validation...
Contacts Authorization Status: ✅ Authorized
✅ CNContactStore access works (test query returned 0 results)
📱 ContactsSyncManager: Found 5 linked people to validate
  • Contact ABC-123-XYZ: .notInSAMGroup (contact exists but not in SAM group)
  • Contact DEF-456-UVW: ✅ valid
  • Contact GHI-789-RST: ✅ valid
  • Contact JKL-012-OPQ: ✅ valid
  • Contact MNO-345-LMN: ✅ valid
📱 ContactsSyncManager: Cleared 1 stale contact link(s)
```

### When Contact Fully Deleted

```
📱 ContactsSyncManager: Starting validation...
Contacts Authorization Status: ✅ Authorized
✅ CNContactStore access works (test query returned 0 results)
📱 ContactsSyncManager: Found 5 linked people to validate
  • Contact ABC-123-XYZ: .contactDeleted
  • Contact DEF-456-UVW: ✅ valid
  • Contact GHI-789-RST: ✅ valid
  • Contact JKL-012-OPQ: ✅ valid
  • Contact MNO-345-LMN: ✅ valid
📱 ContactsSyncManager: Cleared 1 stale contact link(s)
```

---

## When to Use Each Mode

### Strict Mode (`requireSAMGroupMembership = true`) ← **CURRENT**
- **Use when:** You use the SAM group as the "source of truth"
- **Behavior:** Contacts removed from SAM group → auto-unlinked
- **Best for:** Group-based import workflow (your setup)

### Lenient Mode (`requireSAMGroupMembership = false`)
- **Use when:** Contacts might move between groups
- **Behavior:** Only unlinks when contact is fully deleted
- **Best for:** Manual linking workflow (no group import)

---

## Testing Checklist

- [ ] Remove a contact from SAM group → should auto-unlink
- [ ] Delete a contact entirely → should auto-unlink  
- [ ] Contacts in SAM group → should stay linked
- [ ] Banner appears with correct count
- [ ] Debug logs show detailed validation results
- [ ] Performance is acceptable with many linked contacts

Once confirmed working:
- [ ] Disable debug logging: `ContactSyncConfiguration.enableDebugLogging = false`
- [ ] Document in context.md that SAM group filtering is now enabled
