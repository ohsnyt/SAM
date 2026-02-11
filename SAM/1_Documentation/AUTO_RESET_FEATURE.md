# Auto-Reset on Version Change Feature

**Implemented:** February 11, 2026  
**Status:** ✅ Complete

---

## Overview

SAM now includes an automatic reset feature that can clear all data and reset onboarding whenever the app version changes. This is particularly useful during development and testing phases.

---

## What Was Implemented

### 1. New Settings Toggle

**Location:** Settings → General Tab → Automatic Reset section

A new checkbox labeled **"Reset on version change"** has been added with:
- Clear description of what it does
- Warning indicator (⚠️) when enabled showing that data will be cleared on version updates
- Positioned above the manual reset buttons for better organization

### 2. Version Tracking

**Files Modified:**
- `SAMApp.swift` - Added version checking on app launch
- `SettingsView.swift` - Added toggle and dynamic version display

**How It Works:**
1. On every app launch, SAM checks the current version against the last known version
2. Version format: `CFBundleShortVersionString.CFBundleVersion` (e.g., "1.0.0.1")
3. If versions differ AND the setting is enabled, automatic reset occurs
4. Current version is stored in UserDefaults as `lastAppVersion`

### 3. What Gets Reset

When auto-reset triggers, the following happens:
- ✅ Onboarding is marked incomplete (will show on next launch)
- ✅ All UserDefaults settings are cleared:
  - Contact/Calendar group selections
  - Auto-import preferences
  - Last import timestamps
  - Permission settings
- ℹ️ SwiftData is NOT automatically cleared (requires manual deletion or restart)

### 4. Dynamic Version Display

The General tab now shows:
- **Version:** Reads from `CFBundleShortVersionString` in Info.plist
- **Build:** Reads from `CFBundleVersion` in Info.plist

No more hardcoded version strings!

---

## UserDefaults Keys

| Key | Purpose |
|-----|---------|
| `autoResetOnVersionChange` | Boolean - Whether auto-reset is enabled |
| `lastAppVersion` | String - Last known app version (format: "major.minor.patch.build") |

---

## How to Use During Development

### Enabling Auto-Reset

1. Open Settings (⌘,)
2. Go to General tab
3. Enable "Reset on version change"
4. Warning will appear confirming it's active

### Updating the Version Number

You have two options for updating versions:

#### Option A: Manual Updates in Xcode

1. Select your project in the navigator
2. Select the SAM_crm target
3. Go to the "General" tab
4. Update either:
   - **Version** (CFBundleShortVersionString) - for major releases (1.0.0 → 1.0.1)
   - **Build** (CFBundleVersion) - for minor changes (1 → 2)

**Recommendation:** For every code change, increment the **Build** number. This is simpler and fits your workflow.

#### Option B: Using Build Scripts (Advanced)

You can add a build script to auto-increment the build number:

1. In Xcode, select your target
2. Go to Build Phases
3. Add "Run Script" phase
4. Add this script:

```bash
buildNumber=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "${INFOPLIST_FILE}")
buildNumber=$(($buildNumber + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $buildNumber" "${INFOPLIST_FILE}"
```

⚠️ **Note:** I cannot automatically update the version number with every code change because:
- Version numbers are stored in the Info.plist or project settings
- I can only modify files you explicitly show me or that I search for
- Automatically changing versions on every file edit would create noise and make version control difficult

### Recommended Workflow

For development with frequent iterations:

1. Enable "Reset on version change" in Settings
2. When starting a new feature or making significant changes:
   - Increment the Build number in Xcode (e.g., 1 → 2)
   - Launch the app - auto-reset will trigger
   - Fresh start with clean data
3. For daily minor changes:
   - Use manual reset buttons as needed
   - Only increment version when you want full reset

---

## Version Numbering Best Practices

### Apple's Recommended Format

- **Version (CFBundleShortVersionString):** `major.minor.patch`
  - Example: `1.0.0`, `1.1.0`, `2.0.0`
  - User-visible in App Store
  - Semantic versioning

- **Build (CFBundleVersion):** Monotonically increasing number
  - Example: `1`, `2`, `3`, `42`, `100`
  - Internal tracking
  - Must always increase

### For SAM Development

Current version: `1.0.0` Build: `1`

**Suggested scheme:**
- Increment **Build** for every code change you want to test with reset
- Increment **Version** for major milestones:
  - `1.1.0` - Phase F complete
  - `1.2.0` - Phase G complete
  - `2.0.0` - SAM 1.0 release candidate

---

## Code Changes Summary

### SAMApp.swift

**Added:**
```swift
/// Check if app version has changed and auto-reset if enabled
private func checkVersionAndAutoReset() {
    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    let currentBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    let fullVersion = "\(currentVersion).\(currentBuild)"
    
    let lastVersion = UserDefaults.standard.string(forKey: "lastAppVersion")
    let autoResetEnabled = UserDefaults.standard.bool(forKey: "autoResetOnVersionChange")
    
    if let lastVersion = lastVersion, lastVersion != fullVersion, autoResetEnabled {
        // Perform reset...
    }
    
    UserDefaults.standard.set(fullVersion, forKey: "lastAppVersion")
}
```

**Modified:** `init()` to call `checkVersionAndAutoReset()` before loading onboarding state

### SettingsView.swift

**GeneralSettingsView:**

**Added:**
- `@AppStorage("autoResetOnVersionChange")` property
- Dynamic version/build reading from Bundle
- "Automatic Reset" section with toggle and warning
- Reorganized "Development" to "Manual Reset"

---

## Testing the Feature

### Test Case 1: Enable and Trigger

1. Launch SAM and complete onboarding
2. Add some test people/data
3. Open Settings → General
4. Enable "Reset on version change"
5. Note the current version (e.g., "1.0.0" Build "1")
6. Quit SAM
7. In Xcode, increment the Build number to "2"
8. Launch SAM
9. **Expected:** Onboarding should appear (data reset)

### Test Case 2: Disabled Setting

1. Ensure "Reset on version change" is OFF
2. Increment version
3. Launch app
4. **Expected:** No reset, data intact

### Test Case 3: Same Version

1. Enable "Reset on version change"
2. Don't change version
3. Launch app multiple times
4. **Expected:** No reset (version hasn't changed)

---

## Troubleshooting

### "I enabled the setting but reset didn't happen"

Check:
1. Did you actually change the version/build number in Xcode?
2. Check console logs for version messages:
   ```
   🔍 [SAMApp] Current version: 1.0.0.2
   🔍 [SAMApp] Last version: 1.0.0.1
   🔍 [SAMApp] Auto-reset enabled: true
   🔄 [SAMApp] Version changed... - auto-resetting...
   ```

### "How do I know what version I'm on?"

Settings → General tab shows both version and build number dynamically.

### "Can I undo an auto-reset?"

No - once reset, data is cleared. This is intentional for clean testing. If you need to preserve data:
1. Disable the toggle
2. Or manually increment version only when you want reset

---

## Future Enhancements

Potential improvements for later:

- [ ] Option to exclude SwiftData from reset
- [ ] Backup/restore data before reset
- [ ] Version change notification/alert before reset
- [ ] Reset log/history
- [ ] Integration with Git commit hooks for auto-versioning

---

## Related Documentation

- **agent.md** - Product philosophy and development guidelines
- **CLAUDE.md** - Architecture and coding conventions
- **context.md** - Current implementation status

---

**Implementation Complete ✅**

The auto-reset feature is now active and ready for use during development. Remember to increment your build number when you want a fresh start!
