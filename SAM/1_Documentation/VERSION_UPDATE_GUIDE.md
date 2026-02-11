# Quick Guide: Updating Version Numbers in SAM

**For Development Use**

---

## TL;DR

**To trigger auto-reset on next launch:**

1. In Xcode project navigator, select **SAM_crm** project
2. Select **SAM_crm** target
3. Go to **General** tab
4. Under "Identity" → **Build** field, increment the number (e.g., `1` → `2`)
5. Build and run (⌘R)

---

## Where Are Version Numbers?

### In Xcode UI

**Path:** Project → Target → General Tab → Identity Section

You'll see:
```
Display Name:     SAM
Bundle Identifier: com.yourcompany.SAM-crm
Version:          1.0.0         ← Major releases
Build:            1             ← Increment this often
```

### In Info.plist (Alternative)

If you prefer editing the plist directly:

```xml
<key>CFBundleShortVersionString</key>
<string>1.0.0</string>          <!-- Version -->

<key>CFBundleVersion</key>
<string>1</string>              <!-- Build -->
```

---

## When to Update Which Number

### Build Number (CFBundleVersion)

**Increment for:**
- Every code change you want to test fresh ✅
- Daily development iterations ✅
- Bug fixes during testing ✅
- Any time you want auto-reset to trigger ✅

**Examples:**
- `1` → `2` → `3` → `4`...
- Can be any positive integer
- Must always increase

### Version Number (CFBundleShortVersionString)

**Increment for:**
- Completed feature phases ✨
- Major milestones 🎯
- Release candidates 🚀

**Examples:**
- `1.0.0` → `1.1.0` (new feature complete)
- `1.1.0` → `1.2.0` (another feature)
- `1.9.0` → `2.0.0` (major release)

---

## Common Workflows

### Scenario 1: Daily Development

**Goal:** Reset app frequently during active development

```
Day 1:  Build 1 → 2
Day 2:  Build 2 → 3
Day 3:  Build 3 → 4
```

Version stays `1.0.0` until you reach a milestone.

### Scenario 2: Phase Completion

**Goal:** Mark completion of a major feature

```
Complete Phase E:
  Version: 1.0.0 → 1.1.0
  Build:   42 → 43
  
Complete Phase F:
  Version: 1.1.0 → 1.2.0
  Build:   73 → 74
```

### Scenario 3: Quick Iteration

**Goal:** Test the same change multiple times

```
First attempt:  Build 5 → 6  (test, find bug)
Second attempt: Build 6 → 7  (test, find another bug)
Third attempt:  Build 7 → 8  (test, works!)
```

---

## Pro Tips

### ✅ DO

- Increment Build frequently during development
- Use auto-reset feature during active testing
- Keep Version changes for milestones only
- Document version changes in your commit messages

### ❌ DON'T

- Forget to increment before testing reset
- Decrement version numbers (must always increase)
- Use the same version for App Store and internal builds
- Worry about "skipping" numbers - gaps are fine!

---

## Keyboard Maestro / Alfred Snippet (Optional)

If you use automation tools, you can create a quick macro:

**Alfred Snippet:**
```
Trigger: ;samversion
Action: Open Xcode project, select target, focus Build field
```

**Keyboard Maestro:**
```
1. Activate Xcode
2. Press ⌘1 (Project Navigator)
3. Type "SAM_crm" + Enter
4. Press ⌘1 (General Tab)
5. Tab to Build field
```

---

## Checking Current Version

### In the App

Settings (⌘,) → General Tab

Shows:
```
Version: 1.0.0 (Phase E Complete)
Build:   23
```

### In Code

```swift
let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
print("Running version \(version ?? "unknown"), build \(build ?? "unknown")")
```

### In Terminal

```bash
defaults read ~/Library/Preferences/com.yourcompany.SAM-crm.plist lastAppVersion
```

---

## Auto-Increment Script (Advanced)

If you want to auto-increment build on every compile:

### Add Build Phase Script

1. Xcode → Target → Build Phases
2. Click `+` → New Run Script Phase
3. Paste:

```bash
#!/bin/bash

# Auto-increment build number
buildNumber=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "${INFOPLIST_FILE}")
buildNumber=$(($buildNumber + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $buildNumber" "${INFOPLIST_FILE}"

echo "Build number incremented to $buildNumber"
```

4. Drag script to run **before** "Compile Sources"

⚠️ **Warning:** This will increment on EVERY build, even unsuccessful ones. Use with caution!

---

## Version History Example

```
1.0.0.1   - Initial setup (Feb 9, 2026)
1.0.0.2   - Added onboarding flow
1.0.0.3   - Fixed permission bug
1.0.0.15  - Testing complete
1.1.0.16  - Phase E Complete ← Version bump for milestone
1.1.0.17  - Bug fix in settings
1.1.0.25  - Testing new feature
1.2.0.26  - Phase F Complete ← Version bump for milestone
```

---

## Questions?

- "Do I need to update both?" → **No, just Build for most changes**
- "Can I skip numbers?" → **Yes, gaps are fine**
- "What if I forget?" → **App won't reset, manually increment and relaunch**
- "Reset without version change?" → **Use manual "Clear All Data" button**

---

**Last Updated:** February 11, 2026
