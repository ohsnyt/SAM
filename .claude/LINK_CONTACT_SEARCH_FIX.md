# Link Contact Sheet - "Search Contacts App" Fix

## Problem

In `LinkContactSheet`, when the user clicks "Yes, Let's Link" and then clicks the "Search Contacts App" button, nothing happens. The button appears but has no functionality.

## Root Cause

The `openContactPicker()` function was incomplete:

```swift
private func openContactPicker() {
    #if canImport(ContactsUI)
    showingContactPicker = true  // ← Sets state but nothing uses it
    #endif
}
```

The function sets `showingContactPicker = true`, but there's no UI code anywhere in the view that responds to this state change. The variable was essentially dead code.

### Why This Happened

On iOS, SwiftUI provides `CNContactPickerViewController` which can be wrapped and presented. However, on **macOS**, there is no native contact picker view controller available through ContactsUI or any public API.

The original implementation appears to have been a placeholder or an incomplete port from an iOS-style picker.

## Solution

Since macOS doesn't have a system contact picker dialog we can present programmatically, the best approach is to **open the Contacts.app** directly and let the user search/browse there.

### Implementation

**File:** `LinkContactSheet.swift`

```swift
private func openContactPicker() {
    // On macOS, there is no native contact picker like on iOS.
    // The best we can do is open the Contacts app so the user can
    // find/select the contact they want, then come back to SAM and
    // try linking again (which will pick up the contactIdentifier
    // if they create a new contact or select an existing one).
    //
    // This opens Contacts.app and dismisses the sheet.
    NSWorkspace.shared.open(URL(string: "x-apple-contacts://")!)
    
    // Dismiss this sheet since the user will continue in Contacts.app
    // and can re-trigger the link flow after they're done there.
    dismiss()
}
```

Also removed the unused `@State private var showingContactPicker = false` variable.

## User Experience Flow

### Before Fix
1. Click unlinked badge on a person
2. Click "Yes, Let's Link"
3. Click "Search Contacts App"
4. ❌ Nothing happens (button is broken)

### After Fix
1. Click unlinked badge on a person
2. Click "Yes, Let's Link"
3. Click "Search Contacts App"
4. ✅ Contacts.app opens automatically
5. ✅ Sheet dismisses
6. User searches/browses in Contacts.app
7. User returns to SAM
8. If user created a new contact with matching name/email, the next import sync will link them automatically
9. If user found an existing contact, they can use "Create New Contact" flow to associate it

## Why This Approach Works

### macOS Contact Picker Limitations

| Platform | Native Picker Available? | Approach |
|----------|-------------------------|----------|
| **iOS** | ✅ Yes (`CNContactPickerViewController`) | Present picker, get selected contact immediately |
| **macOS** | ❌ No public API | Open Contacts.app, let user work there |

### Alternative Approaches Considered

1. **Build a custom picker UI in SAM**
   - ❌ Complex: requires fetching all contacts, implementing search, building list UI
   - ❌ Maintenance burden: need to handle permission changes, updates, etc.
   - ❌ Redundant: Contacts.app already has a perfect search/browse experience

2. **Use AppleScript to control Contacts.app**
   - ❌ Fragile: AppleScript APIs can break between OS versions
   - ❌ Limited: can't easily return selected contact identifier to SAM
   - ❌ Requires automation permissions

3. **Wait for the user to import via the SAM group** (current approach)
   - ✅ Simple: just open Contacts.app
   - ✅ Leverages existing sync mechanism
   - ✅ User already knows how to use Contacts.app

## Testing

### Test Case: Search for Existing Contact

1. Create an unlinked person in SAM (name: "John Smith")
2. Click the orange unlinked badge
3. Click "Yes, Let's Link"
4. Click "Search Contacts App"

**Expected:**
- ✅ Contacts.app opens
- ✅ LinkContactSheet dismisses
- ✅ User can search for "John Smith" in Contacts.app
- ✅ If user adds John Smith to the SAM group, next sync will link automatically

### Test Case: Create New Contact

Note: The **"Create New Contact"** button has its own flow (via `createNewContact()`) which creates a vCard and opens it in Contacts.app. That flow is separate and already works.

## Future Enhancements

If we want to improve this flow in the future:

1. **Show a hint after opening Contacts.app**
   ```
   "Contacts.app has been opened. After you find or create the contact,
    add them to the 'SAM' group to link automatically, or return here
    and click the unlinked badge again."
   ```

2. **Add a "Watch Clipboard" mode**
   - User selects a contact in Contacts.app
   - Copies the contact card
   - SAM detects contact vCard in clipboard
   - Offers to link automatically

3. **Build a custom in-app search**
   - Fetch all contacts with `CNContactStore`
   - Build a searchable list view
   - Allow selection and immediate linking
   - Pro: no app switching; Con: duplicates Contacts.app UX

## Related Files

- `LinkContactSheet.swift` — Fixed button behavior
- `ContactPresenter.swift` — Handles "Create New Contact" (separate flow, already working)
- `PeopleListView.swift` — Invokes LinkContactSheet from unlinked badge

## Status

✅ **Fix Applied**  
✅ **Ready for Testing**  
📝 **Removed dead code** (`showingContactPicker` state variable)

---

**Next Step:** Click "Search Contacts App" and verify Contacts.app opens correctly.
