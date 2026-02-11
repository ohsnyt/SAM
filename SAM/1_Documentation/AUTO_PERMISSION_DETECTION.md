# Auto-Detect Permission Loss Feature

**Implemented:** February 11, 2026  
**Status:** ✅ Complete

---

## Overview

SAM now automatically detects when permissions have been lost (typically after rebuilding the app in Xcode) and automatically resets onboarding so you can re-grant permissions without manual intervention.

---

## The Problem We Solved

### During Development

When you rebuild a Mac app in Xcode, macOS treats it as a "new" app and **revokes all permissions**:
- ❌ Contacts access: Lost
- ❌ Calendar access: Lost
- ❌ Any other system permissions: Lost

**Before this feature:**
1. Rebuild app
2. Launch app
3. Try to use features → nothing works
4. Remember permissions were lost
5. Go to Settings → General → Reset Onboarding
6. Restart app
7. Go through onboarding again
8. Grant permissions

**After this feature:**
1. Rebuild app
2. Launch app
3. ✨ Onboarding automatically appears
4. Grant permissions
5. Start working immediately

---

## How It Works

### On Every App Launch

SAMApp checks the following logic:

```
1. Has onboarding been completed?
   ├─ NO → Show onboarding (normal first-launch behavior)
   └─ YES → Continue to step 2

2. Is auto-detection enabled? (default: YES)
   ├─ NO → Skip detection, proceed normally
   └─ YES → Continue to step 3

3. Were any sources enabled in settings?
   ├─ NO → Skip detection (user might have skipped all permissions)
   └─ YES → Continue to step 4

4. For each enabled source, check current permission:
   ├─ Contacts enabled but permission ≠ authorized → RESET
   ├─ Calendar enabled but permission ≠ fullAccess → RESET
   └─ All permissions valid → Proceed normally

5. If RESET triggered:
   ├─ Mark onboarding as incomplete
   ├─ Show onboarding sheet
   └─ Log reason for reset
```

### What Gets Reset

When permission loss is detected:
- ✅ Onboarding is marked incomplete
- ✅ Onboarding sheet appears immediately
- ✅ Console logs show detailed reason
- ℹ️ UserDefaults settings are NOT cleared (groups/calendars remembered)
- ℹ️ SwiftData is NOT cleared (people/evidence preserved)

This is **gentler** than the full data reset — it just re-requests permissions.

---

## Settings Control

**Location:** Settings → General Tab → Automatic Reset section

### Toggle: "Auto-detect permission loss (recommended)"

**Default:** ON (enabled by default)

**When Enabled:**
- SAM automatically checks permissions on launch
- If permissions were lost, onboarding appears
- Saves you from manually resetting
- Recommended for development

**When Disabled:**
- No automatic detection
- You must manually use "Reset Onboarding" button
- Useful if you want full control

**Visual Feedback:**
- When OFF: Shows orange warning that auto-detection is disabled
- When ON: No warning (normal behavior)

---

## Use Cases

### Scenario 1: Development Rebuild (Most Common)

**What happens:**
1. You're developing SAM with permissions granted
2. You make code changes and rebuild (⌘R)
3. macOS revokes permissions (sees it as new app)
4. You launch the rebuilt app

**SAM detects:**
- Onboarding was completed: ✅
- Contacts was enabled: ✅
- Contacts permission now: ❌ Not Determined
- **Action:** Auto-reset onboarding

**Result:** Onboarding sheet appears, you grant permissions, continue working

### Scenario 2: User Manually Revoked Permissions

**What happens:**
1. User goes to System Settings
2. Manually revokes Contacts permission
3. Returns to SAM

**SAM detects:**
- Onboarding was completed: ✅
- Contacts was enabled: ✅
- Contacts permission now: ❌ Denied
- **Action:** Auto-reset onboarding

**Result:** User is guided back through onboarding to understand why permissions are needed

### Scenario 3: Fresh Install

**What happens:**
1. User launches SAM for first time
2. No onboarding completed yet

**SAM detects:**
- Onboarding was completed: ❌
- **Action:** Show onboarding (normal behavior)

**Result:** Normal first-launch experience

### Scenario 4: User Skipped All Permissions

**What happens:**
1. User went through onboarding but clicked "Skip" on both Contacts and Calendar
2. User rebuilds app (development)

**SAM detects:**
- Onboarding was completed: ✅
- Contacts enabled: ❌
- Calendar enabled: ❌
- **Action:** No reset (nothing was ever enabled)

**Result:** App launches normally with no permissions

---

## Console Logging

The feature includes comprehensive logging to help you understand what's happening:

### Normal Launch (Permissions Intact)

```
🔧 [SAMApp] Checking permissions and setup...
🔍 [SAMApp] Checking permission state...
🔍 [SAMApp] Settings say - Contacts: true, Calendar: true
🔍 [SAMApp] Contacts permission status: 3 (authorized)
🔍 [SAMApp] Calendar permission status: 4 (fullAccess)
🔧 [SAMApp] Triggering imports for enabled sources...
```

### Launch After Rebuild (Permissions Lost)

```
🔧 [SAMApp] Checking permissions and setup...
🔍 [SAMApp] Checking permission state...
🔍 [SAMApp] Settings say - Contacts: true, Calendar: true
🔍 [SAMApp] Contacts permission status: 0 (notDetermined)
⚠️ [SAMApp] Contacts was enabled but permission is now 0
🔍 [SAMApp] Calendar permission status: 0 (notDetermined)
⚠️ [SAMApp] Calendar was enabled but permission is now 0
⚠️ [SAMApp] Permissions were lost (likely due to rebuild) - resetting onboarding
```

### When Auto-Detection Disabled

```
🔧 [SAMApp] Checking permissions and setup...
🔍 [SAMApp] Auto-detect permission loss is disabled - skipping check
🔧 [SAMApp] Triggering imports for enabled sources...
```

---

## Technical Details

### Files Modified

**SAMApp.swift:**
- Added `checkIfPermissionsLost() async -> Bool`
- Modified `checkPermissionsAndSetup()` to call detection
- Logic runs in `.task` modifier before user interaction

**SettingsView.swift:**
- Added `@AppStorage("autoDetectPermissionLoss")` toggle
- Default value: `true`
- UI in General tab with descriptive text

### UserDefaults Keys

| Key | Type | Purpose | Default |
|-----|------|---------|---------|
| `autoDetectPermissionLoss` | Bool | Enable/disable auto-detection | `true` |
| `sam.contacts.enabled` | Bool | Contacts was enabled during onboarding | `false` |
| `calendarAutoImportEnabled` | Bool | Calendar was enabled during onboarding | `false` |
| `hasCompletedOnboarding` | Bool | Onboarding completion status | `false` |

### Permission Status Values

**CNAuthorizationStatus (Contacts):**
- `0` = notDetermined
- `1` = restricted  
- `2` = denied
- `3` = authorized ← We check for this

**EKAuthorizationStatus (Calendar):**
- `0` = notDetermined
- `1` = restricted
- `2` = denied
- `3` = writeOnly
- `4` = fullAccess ← We check for this

---

## Testing

### Test Case 1: Rebuild Detection

**Steps:**
1. Complete onboarding with both permissions
2. Verify Settings → General shows auto-detect is ON
3. Rebuild app (⌘R in Xcode)
4. Launch

**Expected:**
- ✅ Onboarding sheet appears automatically
- ✅ Console shows permission loss detected
- ✅ Can grant permissions again

### Test Case 2: Disable Auto-Detection

**Steps:**
1. Complete onboarding
2. Settings → General → Turn OFF "Auto-detect permission loss"
3. Rebuild app
4. Launch

**Expected:**
- ❌ No onboarding appears (auto-detect disabled)
- ✅ App launches normally
- ℹ️ Features won't work (permissions lost)
- ✅ Must manually use "Reset Onboarding" button

### Test Case 3: Partial Permissions

**Steps:**
1. Complete onboarding with only Contacts (skip Calendar)
2. Rebuild app
3. Launch

**Expected:**
- ✅ Auto-detect triggers (Contacts was enabled)
- ✅ Onboarding appears
- ✅ Can grant Contacts again
- ℹ️ Calendar still skippable

### Test Case 4: No Permissions Ever

**Steps:**
1. Complete onboarding with no permissions (skip both)
2. Rebuild app
3. Launch

**Expected:**
- ❌ Auto-detect does NOT trigger (nothing was enabled)
- ✅ App launches normally
- ℹ️ No permissions requested

---

## Comparison with Version-Based Reset

You originally asked about version-based resets. Here's why permission detection is better for your use case:

| Feature | Version-Based Reset | Permission Detection |
|---------|---------------------|---------------------|
| **Detects rebuilds** | Only if version changes | ✅ Always |
| **Preserves data** | ❌ Clears everything | ✅ Keeps data |
| **Manual control** | Must remember to change version | ✅ Automatic |
| **False triggers** | Could trigger on actual releases | ✅ Only when needed |
| **Purpose** | Good for testing fresh starts | ✅ Good for development rebuilds |

**Recommendation:** Use both!
- **Permission detection** (default ON): Handles rebuilds automatically
- **Version reset** (default OFF): Use when you want full data wipe

---

## Production Considerations

### Before Release

When you're ready to ship SAM to users:

**Option 1: Keep Feature Enabled**
- ✅ Helps users who manually revoke permissions
- ✅ Guides them back through onboarding
- ✅ Better user experience

**Option 2: Disable for Production**
- Change default to `false` in production builds
- Add compile flag:
  ```swift
  #if DEBUG
  private var defaultAutoDetect = true
  #else
  private var defaultAutoDetect = false
  #endif
  ```

**Recommendation:** Keep it enabled! It helps users recover from permission issues.

---

## Troubleshooting

### "Onboarding keeps appearing after every launch"

**Possible causes:**
1. Permissions aren't actually being granted
   - Check System Settings → Privacy → Contacts/Calendar
   - Verify SAM is in the list and enabled

2. Settings aren't persisting
   - Check console for UserDefaults logs
   - Verify `sam.contacts.enabled` is being set

3. Different app bundle identifier
   - Xcode might be using a different bundle ID
   - Settings are tied to bundle ID

**Fix:** Check console logs to see exact permission status values

### "I want it to stop auto-detecting"

**Solution:**
Settings → General → Turn OFF "Auto-detect permission loss"

### "Can I make it detect but not auto-reset?"

**Not currently.** The feature is all-or-nothing. If you need this, we could add:
- Option to show an alert instead of auto-resetting
- Notification that permissions were lost
- Manual "Re-grant Permissions" button

---

## Future Enhancements

Potential improvements:

- [ ] Show alert before auto-resetting (give user choice)
- [ ] "Quick re-auth" flow (just permissions, skip intro)
- [ ] Detect which specific permission was lost
- [ ] Different behavior for denied vs. notDetermined
- [ ] Track permission loss events for analytics
- [ ] Option to preserve data through reset

---

## Quick Reference

**For daily development:**
1. ✅ Leave "Auto-detect permission loss" ON (default)
2. 🔨 Rebuild as often as you want (⌘R)
3. 🚀 Onboarding appears when needed
4. ⚡️ Grant permissions and continue
5. 🎯 Focus on coding, not permission management

**That's it!** The feature works silently in the background, only intervening when permissions are actually lost.

---

**Last Updated:** February 11, 2026  
**Related:** AUTO_RESET_FEATURE.md, VERSION_UPDATE_GUIDE.md
