# Cleanup Tasks 1 & 2 Implementation Guide

## Task 1: Register `.sam-backup` UTType in Info.plist ✅

### What needs to be done:
The app already uses `UTType.samBackup` in `BackupTab.swift` for file save/open panels, but the OS doesn't know that `.sam-backup` files belong to this app because the type isn't registered in Info.plist.

### Implementation Steps:

#### Option A: Using Xcode UI (Recommended)
1. In Xcode, select the **SAM_crm** app target in the project navigator
2. Go to the **Info** tab
3. Scroll to **Exported Type Identifiers** section (or add it if it doesn't exist)
4. Click the **+** button to add a new exported type
5. Fill in these values:
   - **Identifier:** `com.sam-crm.sam-backup`
   - **Conforms To:** `public.data`
   - **Extensions:** `sam-backup`
   - **Description:** (optional) `SAM Encrypted Backup`

#### Option B: Manual Info.plist XML
If you're editing Info.plist as source code, add this under the root `<dict>`:

```xml
<key>UTExportedTypeDeclarations</key>
<array>
  <dict>
    <key>UTTypeIdentifier</key>
    <string>com.sam-crm.sam-backup</string>
    <key>UTTypeConformsTo</key>
    <array>
      <string>public.data</string>
    </array>
    <key>UTTypeTagSpecification</key>
    <dict>
      <key>public.filename-extension</key>
      <array>
        <string>sam-backup</string>
      </array>
    </dict>
    <key>UTTypeDescription</key>
    <string>SAM Encrypted Backup</string>
  </dict>
</array>
```

### Verification:
After adding this:
1. Clean build folder (⌘⇧K)
2. Rebuild and run
3. Test the export flow — the save panel should now properly default to `.sam-backup` extension
4. Created files should show with a proper app icon (once you assign one) in Finder

---

## Task 2: Remove Tombstone Files ✅

### Files to Remove from Xcode Target:

The following files are confirmed tombstones per `context.md` (all are empty or contain only removal comments):

1. **EvidenceModels.swift** ✓ (Verified - contains only tombstone comment)
2. **MockContextRuntimeStore.swift** ✓ (Per context.md)
3. **MockPeopleRuntimeStore.swift** ✓ (Per context.md)
4. **MockPeopleStore.swift** ✓ (Per context.md)

### Implementation Steps:

1. In Xcode's Project Navigator, locate each file
2. Right-click on the file
3. Choose **"Delete"** from the context menu
4. In the confirmation dialog, select **"Move to Trash"** (not just "Remove Reference")
   - This both removes the reference from the Xcode project AND deletes the file from disk
   - Safe to do since these are confirmed empty tombstones

### Files Already Checked:
- ✅ **EvidenceModels.swift** - Confirmed tombstone with comment:
  ```swift
  // EvidenceModels.swift — TOMBSTONE. Remove from Xcode target (right-click → Remove References).
  // All types migrated to SAMModels.swift (@Model) and SAMModelEnums.swift (value types).
  ```

### Note on MockEvidenceRuntimeStore.swift:
Do **NOT** remove `MockEvidenceRuntimeStore.swift` — according to context.md, this file still exists on disk but contains the live `EvidenceRepository` class. The filename is stale but the class is active code.

---

## Post-Cleanup Verification:

After completing both tasks:

1. ✅ Clean build (⌘⇧K)
2. ✅ Build project (⌘B) — should complete with no errors
3. ✅ Run app and test:
   - Settings → Backup → Export (verify .sam-backup extension works)
   - Settings → Backup → Restore (verify file picker filters correctly)
4. ✅ Search project for any lingering references to removed files:
   - Search for "MockContextRuntimeStore" 
   - Search for "MockPeopleRuntimeStore"
   - Search for "MockPeopleStore"
   - Search for "EvidenceModels" (should only find the import removal comment in context.md)

---

## Risk Assessment:

**Task 1 (UTType registration):** ✅ Zero risk
- Only adds OS-level file type metadata
- No code changes
- Purely additive

**Task 2 (File removal):** ✅ Extremely low risk
- Files are confirmed empty/tombstones
- All live code migrated to SAMModels.swift and SAMModelEnums.swift
- No imports of these files should remain in active code

---

## Timeline:
- **Task 1:** 2 minutes
- **Task 2:** 5 minutes (including verification)
- **Total:** ~7 minutes
