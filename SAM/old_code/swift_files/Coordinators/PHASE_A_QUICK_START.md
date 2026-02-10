# Phase A Quick Start 🚀

## What You Just Got

✅ **6 New Clean Files Created:**
1. `SAMApp.swift` - Minimal app entry point
2. `AppShellView.swift` - Navigation shell with placeholders
3. `SettingsView.swift` - Placeholder settings
4. `PeopleRepository.swift` - Clean repository skeleton
5. `EvidenceRepository.swift` - Clean repository skeleton
6. `PHASE_A_FILE_ORGANIZATION.md` - Detailed instructions

✅ **Reference Documents:**
- `CLEAN_REBUILD_PLAN.md` - Overall strategy
- `PHASE_A_FILE_ORGANIZATION.md` - File moving checklist

---

## Your Next 5 Steps (15 minutes)

### 1. **Add New Files to Xcode** ⏱️ 3 min

In Xcode:
- File → Add Files to "SAM_crm"...
- Select these files (they're in your project folder):
  - `SAMApp.swift`
  - `AppShellView.swift`
  - `SettingsView.swift`
  - `PeopleRepository.swift`
  - `EvidenceRepository.swift`
- **Uncheck** "Copy items if needed"
- **Check** "Add to targets: SAM_crm"
- Click Add

### 2. **Organize Into Groups** ⏱️ 5 min

Drag files in Xcode Project Navigator:
- `SAMApp.swift` → into `App/` group
- `AppShellView.swift` → keep at root level (main SAM_crm group)
- `SettingsView.swift` → into `Views/Settings/` group
- `PeopleRepository.swift` → into `Repositories/` group
- `EvidenceRepository.swift` → into `Repositories/` group

Also move existing good files:
- `SAMModelContainer.swift` → into `App/` group (if not already)
- `PermissionsManager.swift` → into `Services/` group (if not already)
- `SAMModels.swift` → into `Models/SwiftData/` group

### 3. **Delete Old App Entry Point** ⏱️ 1 min

Find old `SAM_crmApp.swift`:
- Right-click → Delete → **Move to Trash**
- (Not "Remove Reference" - actually delete it)

### 4. **Build Project** ⏱️ 1 min

Press **Cmd+B**

You'll see errors - that's expected! Common ones:
- `ContactSyncService` not found (that's old code, remove references)
- `FixtureSeeder` not found (we'll add back in Phase C if needed)
- Missing imports

### 5. **Report Errors** ⏱️ 5 min

**Tell me:**
1. How many errors you see
2. The first 3-5 error messages
3. Which files they're in

I'll help you fix them quickly!

---

## Expected Result After Phase A

When you run the app (even with errors initially):

**✅ Success looks like:**
- App compiles (after we fix errors)
- Window opens
- Shows navigation sidebar: Awareness, Inbox, People, Contexts
- Detail view shows placeholder "Coming in Phase X"
- Settings window opens (macOS only)

**🎉 You'll have a working app shell ready for Phase B!**

---

## If Something Goes Wrong

### Build fails with "@main attribute already exists"
→ You have two app entry points. Delete the old `SAM_crmApp.swift`

### "Cannot find 'ContactSyncService' in scope"
→ That's old code. Look for this in `SAMApp.swift` or other files and comment it out

### "Cannot find 'FixtureSeeder' in scope"
→ Comment out the FixtureSeeder line in `SAMApp.swift` (it's already marked TODO)

### "Cannot find type 'SamPerson' in scope"
→ Make sure `SAMModels.swift` is in `Models/SwiftData/` group and added to target

### Missing imports
→ Add at top of file:
```swift
import SwiftUI
import SwiftData
import Foundation
```

---

## What NOT to Do Right Now

❌ Don't try to implement full features yet  
❌ Don't copy code from `old_code/` yet  
❌ Don't add ContactsService yet (that's Phase B)  
❌ Don't try to make imports work yet (that's Phase C)  

**Just get the skeleton app running!** 🏗️

---

## Ready to Continue?

Once you have:
- ✅ All files organized into groups
- ✅ Project builds without errors
- ✅ App launches and shows placeholders

Tell me **"Phase A complete"** and we'll move to **Phase B: Services Layer** where we build `ContactsService` and see real data! 🚀

---

## Timeline Estimate

- **Phase A (Foundation)**: 30 minutes - Getting skeleton to run
- **Phase B (Services)**: 2 hours - Build ContactsService, see real contact data
- **Phase C (Data Layer)**: 2 hours - Import contacts into SwiftData
- **Phase D (People Views)**: 3 hours - Full people list and detail views
- **Phase E onwards**: 1-2 days per phase

**You're making great progress! Keep going!** 💪
