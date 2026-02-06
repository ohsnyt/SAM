# Link Contact Sheet - "Search Contacts App" Fix

## Problem

In `LinkContactSheet`, when the user clicks "Yes, Let's Link" and then clicks the "Search Contacts App" button, it shows an error: **"There is no application set to open the URL x-apple-contacts://."**

## Root Cause

### Issue #1: No Implementation (Initial State)
The `openContactPicker()` function was incomplete:

```swift
private func openContactPicker() {
    #if canImport(ContactsUI)
    showingContactPicker = true  // ← Sets state but nothing uses it
    #endif
}
```

### Issue #2: Wrong URL Scheme (First Fix Attempt)
Initial fix used `x-apple-contacts://` URL scheme:

```swift
NSWorkspace.shared.open(URL(string: "x-apple-contacts://")!)
```

**Problem:** This URL scheme doesn't exist on macOS. It either doesn't exist at all, or is iOS-only. macOS returns the error: "There is no application set to open the URL."

### Why This Is Tricky

On iOS, SwiftUI provides `CNContactPickerViewController` which can be wrapped and presented. However, on **macOS**, there is no native contact picker view controller available through ContactsUI or any public API.

Additionally, URL schemes for opening system apps vary between platforms:
- iOS: `contacts://` works to open Contacts.app
- macOS: **No URL scheme** — must use file path or bundle identifier

## Solution (Final Fix)

Open Contacts.app using its direct **file path** instead of a URL scheme.

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
    // Open Contacts.app using its file path (works on macOS).
    let contactsAppURL = URL(fileURLWithPath: "/System/Applications/Contacts.app")
    NSWorkspace.shared.open(contactsAppURL)
    
    // Dismiss this sheet since the user will continue in Contacts.app
    // and can re-trigger the link flow after they're done there.
    dismiss()
}
```

Also removed the unused `@State private var showingContactPicker = false` variable.

## macOS App Opening Methods

| Method | Works? | Notes |
|--------|--------|-------|
| `x-apple-contacts://` URL | ❌ No | URL scheme doesn't exist on macOS |
| `contacts://` URL | ❌ No | iOS-only URL scheme |
| Bundle ID `com.apple.Contacts` | ✅ Yes | Via `NSWorkspace.launchApplication()` |
| File path `/System/Applications/Contacts.app` | ✅ Yes | **Direct, reliable, simple (chosen)** |
| AppleScript | ✅ Yes | Requires automation permissions, fragile |

We chose the **file path** approach because:
- ✅ Simple and direct
- ✅ No additional permissions required
- ✅ Works on all recent macOS versions
- ✅ Standard macOS pattern
- ✅ Same approach used by Apple's own apps

## User Experience Flow

### Before Fix
1. Click unlinked badge on a person
2. Click "Yes, Let's Link"
3. Click "Search Contacts App"
4. ❌ Error: "There is no application set to open the URL x-apple-contacts://."

### After Fix
1. Click unlinked badge on a person
2. Click "Yes, Let's Link"
3. Click "Search Contacts App"
4. ✅ Contacts.app opens automatically
5. ✅ Sheet dismisses
6. User searches/browses in Contacts.app
7. User returns to SAM
8. User adds the contact to the "SAM" group
9. Next sync automatically links the person

## Testing

### Test Case: Open Contacts.app

1. Create an unlinked person in SAM (name: "John Smith")
2. Click the orange unlinked badge
3. Click "Yes, Let's Link"
4. Click "Search Contacts App"

**Expected:**
- ✅ Contacts.app opens
- ✅ No error messages
- ✅ LinkContactSheet dismisses
- ✅ User can search/browse contacts

### Test Case: Full Linking Flow

**Scenario A: Link to existing contact**
1. In Contacts.app, find an existing contact "Jane Doe"
2. Add "Jane Doe" to the "SAM" group
3. Return to SAM
4. Click "Sync Now" in Settings → Permissions (Contacts) or People tab
5. **Expected:** "Jane Doe" person is now linked (shows photo, no unlinked badge)

**Scenario B: Create new contact**
1. In Contacts.app, create a new contact "John Smith"
2. Add them to the "SAM" group
3. Return to SAM
4. Click "Sync Now"
5. **Expected:** Existing unlinked "John Smith" person is now linked to the new contact

## Platform Differences

| Platform | Method to Open Contacts | URL/Path |
|----------|------------------------|----------|
| **macOS** | File path | `/System/Applications/Contacts.app` |
| **iOS** | URL scheme | `contacts://` |

**Key takeaway:** URL schemes for system apps are **not portable** between iOS and macOS. Always test platform-specific app launching code on the target platform.

## Alternative Approaches Considered

1. **Bundle identifier with `NSWorkspace.launchApplication()`**
   ```swift
   NSWorkspace.shared.launchApplication(
       withBundleIdentifier: "com.apple.Contacts",
       options: [],
       additionalEventParamDescriptor: nil,
       launchIdentifier: nil
   )
   ```
   - ✅ Also works
   - ➖ More verbose
   - ➖ Requires knowing the bundle ID

2. **Build a custom picker UI in SAM**
   - ❌ Complex: requires fetching all contacts, implementing search, building list UI
   - ❌ Maintenance burden: permission changes, updates, etc.
   - ❌ Redundant: Contacts.app already has perfect search/browse

3. **Use AppleScript to control Contacts.app**
   - ❌ Fragile: APIs can break between OS versions
   - ❌ Limited: can't easily return selected contact identifier
   - ❌ Requires automation permissions

## Future Enhancements

1. **Show a hint after opening Contacts.app**
   Display a banner or alert:
   ```
   "Contacts.app has been opened. After you find or create the contact,
    add them to the 'SAM' group to link automatically."
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
   - Pro: no app switching; Con: duplicates system UX

## Related Files

- `LinkContactSheet.swift` — Fixed button behavior
- `ContactPresenter.swift` — Handles "Create New Contact" (separate flow)
- `PeopleListView.swift` — Invokes LinkContactSheet from unlinked badge
- `context.md` — Updated with correct file path approach

## Status

✅ **Fix Applied**  
✅ **Ready for Testing**  
📝 **Removed dead code** (`showingContactPicker` state variable)  
🔧 **Corrected URL scheme** (file path instead of `x-apple-contacts://`)

---

**Next Step:** Click "Search Contacts App" and verify Contacts.app opens without errors.
