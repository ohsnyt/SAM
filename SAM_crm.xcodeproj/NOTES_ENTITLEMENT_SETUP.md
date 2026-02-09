# Contact Notes Entitlement - Development Mode

## Current Status: ⏳ PENDING APPLE APPROVAL

The SAM app requires special permission from Apple to read and write Contact Notes. While we wait for this entitlement to be granted (estimated 1 week), the app is configured to **log** what would be written to notes instead of actually writing them.

## What Works Now

✅ All contact operations (read contact info, add family members, etc.)  
✅ AI generates note suggestions  
✅ User can review and approve note suggestions  
✅ **Notes are logged to console** with clear formatting  
⏳ Actual writing to Contact Notes (pending entitlement)

## Development Mode Behavior

When you approve an AI-generated note:
1. The note text is displayed in the approval sheet
2. When you click "Approve", the app logs:
   ```
   📝 [ContactSyncService] WOULD UPDATE NOTE for John Doe:
      Note content to add:
      ─────────────────────
      [AI-generated note content here]
      ─────────────────────
      ⚠️  Skipped: Notes entitlement not yet granted by Apple
   ```
3. No error is shown - it behaves as if successful
4. The Person Detail view shows a yellow banner explaining notes are pending

## Viewing Logged Notes

**In Xcode:**
1. Open the Debug Console (Cmd+Shift+C)
2. Look for log lines starting with `📝 [ContactSyncService]`
3. The note content is clearly formatted between separator lines

**Example Console Output:**
```
📝 [ContactSyncService] WOULD UPDATE NOTE for Harvey Chen:
   Note content to add:
   ─────────────────────
   Harvey is a senior engineering leader with expertise in distributed systems. 
   Known for mentoring junior developers and leading cross-functional teams.
   ─────────────────────
   ⚠️  Skipped: Notes entitlement not yet granted by Apple
```

## Enabling Notes Access (Once Approved)

When Apple grants the Notes entitlement:

### Step 1: Update Code Flags
Edit **ContactSyncService.swift** (line ~41):
```swift
private let hasNotesEntitlement = true  // Change false to true
```

Edit **PersonDetailSections.swift** (line ~442):
```swift
private let hasNotesEntitlement = true  // Change false to true
```

### Step 2: Uncomment CNContactNoteKey
Edit **ContactSyncService.swift** (line ~61):
```swift
private static let allContactKeys: [CNKeyDescriptor] = [
    // ... other keys ...
    CNContactNoteKey,  // Uncomment this line
    // ... rest of keys ...
]
```

### Step 3: Add Entitlement to .entitlements File
Add to your app's entitlements file:
```xml
<key>com.apple.security.personal-information.contacts</key>
<true/>
```

### Step 4: Test
1. Clean build folder (Cmd+Shift+K)
2. Build and run
3. Generate an AI note suggestion
4. Approve it
5. Open Contacts.app and verify the note was written

## Testing Checklist

Before enabling (development mode):
- [ ] AI note generation works
- [ ] Note approval sheet displays correctly
- [ ] Console logs show note content clearly
- [ ] No crashes or errors
- [ ] Person detail view shows "Notes Access Pending" banner

After enabling (production mode):
- [ ] Notes appear in the Person Detail view
- [ ] Notes are written to Contacts.app
- [ ] Existing notes are preserved (appended, not replaced)
- [ ] No "property not fetched" errors
- [ ] No console warnings about entitlements

## Code Locations

| File | Line | What to Change |
|------|------|----------------|
| ContactSyncService.swift | ~41 | `hasNotesEntitlement = true` |
| ContactSyncService.swift | ~61 | Uncomment `CNContactNoteKey` |
| PersonDetailSections.swift | ~442 | `hasNotesEntitlement = true` |
| SAM_crm.entitlements | N/A | Add contacts entitlement |

## Questions?

If you see any of these errors:
- ❌ "A property was not requested" → Make sure `CNContactNoteKey` is uncommented
- ❌ "Attempt to read notes by unentitled app" → Entitlement not yet granted by Apple
- ❌ Contact notes showing as empty → Check that `hasNotesEntitlement` is set correctly

All changes are clearly marked with `TODO:` comments and the feature flag pattern makes it easy to enable/disable.
