# Phase B: Services Layer - Setup Instructions

**Date**: February 9, 2026  
**Status**: Ready to Test  
**Time Estimate**: 15-30 minutes to add files and test

---

## What We Built

✅ **Three new files created:**

1. **`ContactDTO.swift`** - Sendable wrapper for CNContact data
   - Location: `Models/DTOs/ContactDTO.swift`
   - Allows contact data to cross actor boundaries safely
   - Includes nested types for phone numbers, addresses, relations, etc.
   - Defines key sets (.minimal, .detail, .full) for efficient fetching

2. **`ContactsService.swift`** - Actor-based service for Contacts framework
   - Location: `Services/ContactsService.swift`
   - Singleton: `ContactsService.shared`
   - All CNContactStore operations go through here
   - Methods: authorization, fetch single/multiple, search, groups

3. **`ContactsTestView.swift`** - Test UI to verify everything works
   - Location: `Views/People/ContactsTestView.swift`
   - Shows authorization status
   - Lists contact groups
   - Displays contacts with photos/initials
   - Accessible via dev menu in sidebar

✅ **AppShellView updated** with dev tools menu (DEBUG only)

---

## Your Next Steps

### 1. Add Files to Xcode (10 min)

In Xcode, add these three new files:

**File → Add Files to "SAM_crm"...**

Add each file to the project:
- `ContactDTO.swift` → Add to `Models/DTOs/` group
- `ContactsService.swift` → Add to `Services/` group  
- `ContactsTestView.swift` → Add to `Views/People/` group

**Important:**
- ✅ Check "Add to targets: SAM_crm"
- ⚠️ Uncheck "Copy items if needed" (files are already there)

### 2. Build Project (1 min)

Press **Cmd+B** to build

**Expected result:** Build succeeds ✅

**If you see errors:**
- Missing imports? → Make sure all three files are added to target
- Can't find types? → Check that `ContactDTO.swift` is in the project
- Other errors? → Tell me what you see!

### 3. Run App (5 min)

Press **Cmd+R** to run the app

**You should see:**
- Main SAM window opens
- Sidebar on left (Awareness, Inbox, People, Contexts)
- **NEW:** Small "Dev Tools" menu in sidebar toolbar (hammer icon)

### 4. Test Contacts Service (10 min)

Click the **hammer icon** in sidebar toolbar → **"Test Contacts Service"**

A test window will open. Here's what to do:

#### Step 1: Request Access
1. Click **"Request Access"** button
2. macOS will show permission dialog
3. Click **Allow** to grant Contacts access
4. Status should change to "Authorized" ✅

#### Step 2: Fetch Groups
1. Click **"Fetch Groups"** button
2. You should see your contact groups appear (e.g., "SAM", "Family", "Work")
3. Each group has a "Load" button

#### Step 3: Load Contacts
Option A: **Load from specific group**
- Click "Load" next to a group name (e.g., "SAM")
- Contacts from that group appear below

Option B: **Load all contacts**
- Click "Load All Contacts" at bottom
- All contacts appear (this might take a few seconds if you have many)

#### Step 4: Verify Contact Display
Each contact should show:
- ✅ Contact photo (if they have one) OR colored circle with initials
- ✅ Full name
- ✅ Organization (if they have one)
- ✅ First phone number (if they have one)

---

## Success Criteria ✅

You'll know Phase B is complete when:

- [ ] All three files build without errors
- [ ] App runs without crashes
- [ ] Dev Tools menu appears in sidebar
- [ ] Test view opens when clicked
- [ ] Contacts authorization can be granted
- [ ] Contact groups are fetched and displayed
- [ ] Contacts display with photos/initials
- [ ] No concurrency warnings in console

---

## What This Proves

**Architecture validation:**
- ✅ Services layer works (actor-based, no concurrency issues)
- ✅ DTOs work (Sendable data crosses actor boundaries)
- ✅ Views can fetch external data cleanly
- ✅ No direct CNContactStore access outside service

**Phase B complete = Foundation for all future features!**

---

## Troubleshooting

### "Cannot find 'ContactDTO' in scope"
→ Make sure `ContactDTO.swift` is added to target

### "Cannot find 'ContactsService' in scope"  
→ Make sure `ContactsService.swift` is added to target

### "Cannot find 'ContactsTestView' in scope"
→ Make sure `ContactsTestView.swift` is added to target  
→ AppShellView needs `#if DEBUG` wrapper (already done)

### "Use of unavailable macro '#Predicate'"
→ This is from old code - ignore for now, we'll fix in Phase C

### Contacts not showing up
→ Check Console (Cmd+Shift+Y) for log messages
→ Look for `[ContactsService]` logs
→ Make sure you granted Contacts permission

### Dev menu not appearing
→ Make sure you're running DEBUG build (not Release)
→ Check that AppShellView changes were saved

---

## What's Next After Phase B?

Once you've verified contacts are loading:

**Phase C: Data Layer** - Import contacts into SwiftData
- Build `PeopleRepository` properly
- Create `ContactsImportCoordinator`
- Wire up import flow in Settings
- See contacts persist across app launches

**Then:**
- Phase D: Full People views (list + detail)
- Phase E: Calendar service + Evidence
- Phase F-I: Rest of the app

---

## Report Back

When you've tested, tell me:

1. ✅ Did build succeed?
2. ✅ Did app launch?
3. ✅ Did dev menu appear?
4. ✅ Did test view work?
5. ✅ Did contacts load with photos?

If anything failed, copy the error messages!

---

**Ready? Add the files and let's test!** 🚀
