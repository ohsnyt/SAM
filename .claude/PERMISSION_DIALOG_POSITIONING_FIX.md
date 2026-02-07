# Permission Dialog Positioning Fix

## Problem
When clicking Calendar or Contacts permission buttons in the Settings → Permissions tab, the system permission dialog appeared centered on the screen, requiring users to scroll away from their current Settings window to interact with it.

## Solution
Implemented **intermediate confirmation alerts** that appear as sheets attached to the Settings window. These alerts:
1. Explain what permission is being requested and why
2. Inform users that a system dialog will appear next
3. Allow users to cancel or proceed
4. Are positioned directly on the Settings window (no scrolling needed)

## Changes Made

### 1. Added State Variables for Alert Presentation
```swift
// Permission request confirmation states
@State private var showingCalendarPermissionConfirmation = false
@State private var showingContactsPermissionConfirmation = false
```

### 2. Added Confirmation Alerts to Body
Two `.alert()` modifiers attached to the main TabView:

**Calendar Alert:**
- Title: "Calendar Access Required"
- Message: Explains SAM needs calendar access and that a system dialog will appear
- Actions: Cancel or Request Access

**Contacts Alert:**
- Title: "Contacts Access Required"  
- Message: Explains SAM needs contacts access and that a system dialog will appear
- Actions: Cancel or Request Access

### 3. Modified Button Actions
Changed button actions in `PermissionsTab` to show confirmation alerts instead of directly requesting permissions:

**Before:**
```swift
Button("Request Calendar Access") {
    Task { await requestCalendarAccessAndReload() }
}
```

**After:**
```swift
Button("Request Calendar Access") {
    showingCalendarPermissionConfirmation = true
}
```

### 4. Created Separate Request Functions
Renamed functions to clarify the flow:
- `requestCalendarAccessAndReload()` → Shows confirmation alert
- `performCalendarAccessRequest()` → Actually requests permission (called after confirmation)

Same pattern for Contacts.

## User Experience Flow

### Before
1. Click "Request Calendar Access" button
2. System dialog appears centered on screen (potentially off-view)
3. User scrolls to find and interact with dialog

### After
1. Click "Request Calendar Access" button
2. **Confirmation alert appears on Settings window** ✨ (no scrolling needed)
3. Read explanation of what will happen
4. Click "Request Access" or "Cancel"
5. If confirmed, system dialog appears (user is now prepared)

## Benefits
- ✅ User stays focused on Settings window
- ✅ Clear explanation before system dialog
- ✅ Option to cancel without triggering system dialog
- ✅ Better context about what permission is needed and why
- ✅ Follows Apple's progressive disclosure pattern
- ✅ Native SwiftUI alerts are always positioned relative to their parent window

## Testing
1. Open Settings → Permissions tab
2. Position window anywhere on screen
3. Click "Request Calendar Access"
4. Verify alert appears directly on Settings window
5. Click "Request Access"
6. System permission dialog appears
7. Repeat for "Request Contacts Access"
