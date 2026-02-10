# Phase A File Organization Guide

## Files to Move (Do This Now)

### 1. Move to `App/` Group
- [x] `SAMModelContainer.swift` - Already good, keep as-is
- [ ] `SAMApp.swift` - **REPLACE** with new clean version (delete old, use new one created)

### 2. Move to `Services/` Group
- [x] `PermissionsManager.swift` - Already good, keep as-is

### 3. Move to `Models/SwiftData/` Group
- [ ] `SAMModels.swift` - **MOVE** this file here, it contains all your @Model classes

### 4. Move to `Views/Settings/` Group  
- [ ] `SettingsView.swift` - **REPLACE** with new placeholder (delete old, use new)

### 5. Move to Root of `SAM_crm` Group (main level)
- [ ] `AppShellView.swift` - **NEW** file, add to project

### 6. Move to `Repositories/` Group
- [ ] `PeopleRepository.swift` - **REPLACE** with new clean version
- [ ] `EvidenceRepository.swift` - **REPLACE** with new clean version

### 7. Move to `Utilities/` Group
- [ ] `DevLogger.swift` - Keep as-is (if you have it)

---

## Files Already in `old_code/` - Reference Only

These should all be in `old_code/swift_files/` now:
- Old `SAM_crmApp.swift`
- Old `ContactsImportCoordinator.swift`
- Old `CalendarImportCoordinator.swift`
- Old `PersonDetailView.swift`
- Old `ContactValidator.swift`
- Old `MeCardManager.swift`
- All other view files
- All other coordinator files

**Do NOT add these back to the project yet.** We'll rebuild them properly in Phases B-I.

---

## How to "Replace" a File

For files marked **REPLACE**:

1. **Delete the old version**:
   - Find the old file in Xcode (probably in root or `old_code/`)
   - Right-click → Delete → **Move to Trash** (not just "Remove Reference")

2. **Add the new version**:
   - The new file was created in `/repo/` by me
   - In Xcode: File → Add Files to "SAM_crm"...
   - Navigate to find the new file (it's in your project directory)
   - Make sure "Copy items if needed" is **unchecked** (file is already there)
   - Make sure "Add to targets" includes **SAM_crm**
   - Click Add
   - Drag it into the appropriate group folder

---

## Next Steps After Organization

Once you've moved all files to their new groups:

1. **Build the project** (Cmd+B)
2. **You'll see compile errors** - that's expected! We need to add missing pieces:
   - `ContactDTO` (Phase B)
   - `EventDTO` (Phase E)
   - Actual implementations of repositories (Phase C & E)

3. **Tell me what errors you see** and I'll help you fix them one by one.

---

## Expected Project Structure After Phase A

```
SAM_crm (group)
├── App/
│   ├── SAMModelContainer.swift      ✅ Existing, keep as-is
│   └── SAMApp.swift                 🆕 New clean version
│
├── Services/
│   └── PermissionsManager.swift     ✅ Existing, keep as-is
│
├── Repositories/
│   ├── PeopleRepository.swift       🆕 New clean version
│   └── EvidenceRepository.swift     🆕 New clean version
│
├── Models/
│   ├── SwiftData/
│   │   └── SAMModels.swift          ✅ Existing, move here
│   └── DTOs/
│       └── (empty for now)
│
├── Views/
│   ├── People/        (empty)
│   ├── Inbox/         (empty)
│   ├── Contexts/      (empty)
│   ├── Awareness/     (empty)
│   └── Settings/
│       └── SettingsView.swift       🆕 New placeholder
│
├── Utilities/
│   └── DevLogger.swift              ✅ If you have it
│
├── AppShellView.swift               🆕 New file (root level)
│
└── old_code/ (blue folder)
    └── swift_files/
        └── [50+ old files for reference]
```

---

## Verification Checklist

After moving files:

- [ ] `SAMModelContainer.swift` is in `App/` group
- [ ] `PermissionsManager.swift` is in `Services/` group
- [ ] `SAMModels.swift` is in `Models/SwiftData/` group
- [ ] New `SAMApp.swift` is in `App/` group
- [ ] New `AppShellView.swift` is at root level
- [ ] New `SettingsView.swift` is in `Views/Settings/` group
- [ ] New repository files are in `Repositories/` group
- [ ] Old code is all in `old_code/` and NOT in any other group
- [ ] Project builds with errors (expected - missing pieces)

---

Ready? Start moving files and let me know when you hit errors! 🚀
