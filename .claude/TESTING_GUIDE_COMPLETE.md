# End-to-End Testing Guide: Contacts-as-Identity

**Date:** 2026-02-07  
**Status:** Ready for Testing  
**Goal:** Verify complete flow from note extraction → family addition → display in Contacts & SAM

---

## ✅ Pre-Flight Checklist

Before running tests, verify:

- [ ] All files compiled without errors
- [ ] `PersonDetailSections.swift` imported into Xcode project
- [ ] `ContactSyncService.swift` imported into Xcode project
- [ ] `AddRelationshipSheet.swift` imported into Xcode project
- [ ] SAM app launches successfully
- [ ] Contacts permission granted (Settings → Permissions → Contacts)
- [ ] At least one person exists with `contactIdentifier` (e.g., Harvey Snodgrass from fixtures)

---

## 🧪 Test Suite

### Test 1: Basic App Initialization

**Goal:** Verify ContactSyncService configured correctly

**Steps:**
1. Launch SAM app
2. Check console output

**Expected Console Output:**
```
[App] About to configure repositories...
[App] Repositories configured.
[App] ContactSyncService configured.
[App] Contact cache refresh complete.
```

**Pass Criteria:**
- ✅ No crashes on launch
- ✅ Console shows ContactSyncService configured
- ✅ Cache refresh completes (may take 1-5 seconds)

**If Fails:**
- Check that `ContactSyncService.swift` is in build target
- Verify Contacts authorization granted
- Check for import errors in console

---

### Test 2: View Person Detail with Contacts Data

**Goal:** Verify Family/Contact sections display from CNContact

**Prerequisites:**
- Harvey Snodgrass exists in SAM
- Harvey has a linked contact in Contacts.app
- Harvey's contact has family members (spouse, children)

**Steps:**
1. Launch SAM
2. Navigate to People tab
3. Click on Harvey Snodgrass
4. Wait for detail view to load (1-2 seconds)

**Expected Display:**
```
Harvey Snodgrass
Client

[Loading indicator briefly]
  ↓
👨‍👩‍👦 Family & Relationships
  ❤️ Sarah (spouse)
  👤 Emily (daughter)
  🎂 Birthday: [date if set]
  [Edit in Contacts]

📞 Contact Information
  📱 [phone if set]
  📧 [email if set]
  
💼 Professional
  [Company/title if set]

📝 Summary
  [Note if set]
  [✨ Suggest AI Update] [✏️ Edit in Contacts]

[Existing SAM sections follow]
```

**Pass Criteria:**
- ✅ Family section appears (if contact has relations)
- ✅ Contact Info section appears (if contact has phone/email)
- ✅ No crashes or blank screens
- ✅ "Edit in Contacts" button present

**If Sections Don't Appear:**
- Check Harvey has `contactIdentifier` set
- Verify contact exists in Contacts.app
- Check console for errors
- Verify Contacts permission granted

---

### Test 3: Create Note and Extract Person

**Goal:** Verify LLM extracts person with relationship

**Steps:**
1. Navigate to Inbox tab
2. Click "Add Note" button
3. Enter note text:
   ```
   I just had a son. His name is William. I want William to have 
   a $60,000 life insurance policy.
   ```
4. Select Harvey Snodgrass as linked person
5. Click "Save"
6. Wait for analysis (2-3 seconds)
7. Select new evidence item in Inbox

**Expected Display:**
```
Note
📝 Feb 7, 2026
Needs Review

[AI Analysis Card]
🧠 On-Device LLM

People (2) ▼
  👤 William (son) [NEW] [➕ Add to Harvey's Family]
  👤 Advisor (Financial Advisor)

Financial Topics (1) ▼
  💰 Life Insurance
    $60,000
    For: William
    Sentiment: wants

[Rest of evidence detail]
```

**Pass Criteria:**
- ✅ AI Analysis card appears
- ✅ William detected as "son"
- ✅ "Add to Harvey's Family" button present (not "Add Contact")
- ✅ Financial topic extracted with amount
- ✅ "NEW" badge on William

**If Extraction Fails:**
- Check `NoteLLMAnalyzer` is working
- Verify `SamAnalysisArtifact` created
- Check console for analysis logs
- Try simpler note text

---

### Test 4: Add Family Member with Editable Sheet

**Goal:** Verify editable relationship sheet and CNContact write

**Prerequisites:**
- Test 3 completed (William extracted)

**Steps:**
1. Click [➕ Add to Harvey's Family] next to William
2. **Sheet opens** with:
   - Name: "William"
   - Relationship: "Son" (dropdown)
3. **Optional:** Edit name to "Will"
4. **Optional:** Change relationship to "Step-son" (dropdown or custom)
5. Click "Add to Contacts"
6. Wait for success banner (1-2 seconds)

**Expected Behavior:**
```
[Sheet opens]
┌─────────────────────────────────────┐
│  👤 Add Family Member               │
│  Adding to Harvey Snodgrass's family│
├─────────────────────────────────────┤
│  Name: [William         ]           │
│  Relationship: [Son ▼] [✏️]        │
│  Preview: 👤 William (son)          │
├─────────────────────────────────────┤
│  [Cancel]      [Add to Contacts]    │
└─────────────────────────────────────┘

[After clicking Add]
✅ Added William to Harvey Snodgrass's family in Contacts
[Auto-dismisses after 5 seconds]
```

**Pass Criteria:**
- ✅ Sheet opens with pre-filled data
- ✅ Name field editable
- ✅ Relationship picker works
- ✅ Custom relationship text entry available (click pencil icon)
- ✅ "Add to Contacts" button enabled
- ✅ Success banner appears
- ✅ Sheet dismisses

**If Sheet Doesn't Open:**
- Check `AddRelationshipSheet.swift` imported
- Verify `NoteArtifactDisplay` updated correctly
- Check console for errors

**If Write Fails:**
- Verify Contacts permission granted
- Check Harvey's contact exists in Contacts.app
- Look for error banner with message

---

### Test 5: Verify in Contacts.app

**Goal:** Confirm William appears in Harvey's CNContact

**Prerequisites:**
- Test 4 completed (William added)

**Steps:**
1. Open **Contacts.app** (macOS)
2. Search for "Harvey Snodgrass"
3. Open Harvey's contact
4. Scroll to "Related People" or "Related Names" section

**Expected Display:**
```
Harvey Snodgrass
[Photo]
[Phone/Email]

Related Names:
  William (son)    [or (step-son) if you changed it]
```

**Pass Criteria:**
- ✅ William appears in Related Names
- ✅ Relationship label correct ("son" or custom label)
- ✅ No duplicate entries
- ✅ Data persisted (close and reopen contact)

**If William Doesn't Appear:**
- Check Contacts permission granted
- Verify no error banner appeared in SAM
- Try manual refresh (close/reopen Contacts.app)
- Check console for CNContactStore errors

---

### Test 6: Verify in SAM PersonDetailView

**Goal:** Confirm William appears in Harvey's Family section

**Prerequisites:**
- Test 5 passed (William in Contacts.app)

**Steps:**
1. Return to SAM app
2. Navigate to People → Harvey Snodgrass
3. Scroll to Family & Relationships section
4. **Or:** Close detail → Reopen to force fresh load

**Expected Display:**
```
👨‍👩‍👦 Family & Relationships
  ❤️ Sarah (spouse) → [View]
  👤 William (son) → [View]    ⭐️ NEW
  👤 Emily (daughter) → [View]
  [Edit in Contacts]
```

**Pass Criteria:**
- ✅ William appears in Family section
- ✅ Relationship label matches ("son" or custom)
- ✅ Sorted correctly (children grouped together)
- ✅ Icon correct (person.fill for child)

**If William Doesn't Appear:**
- Check cache refresh triggered
- Manually trigger refresh (close/reopen SAM)
- Verify Harvey's contactIdentifier valid
- Check console for refresh errors

---

### Test 7: Edit Relationship Label (Custom)

**Goal:** Verify custom relationship labels work

**Steps:**
1. Create note: "My step-daughter Emily graduated"
2. Extract Emily (should detect "step-daughter")
3. Click "Add to Harvey's Family"
4. **In sheet:** Click pencil icon next to relationship
5. Type custom label: "goddaughter"
6. Click "Add to Contacts"

**Expected:**
- Sheet shows custom text field
- "goddaughter" accepted as valid label
- Success banner appears
- Contacts.app shows "Emily (goddaughter)"
- SAM shows "Emily (goddaughter)" in Family section

**Pass Criteria:**
- ✅ Custom label accepted (any string)
- ✅ No validation errors
- ✅ Appears correctly in both apps

---

### Test 8: Orphaned Contact Handling

**Goal:** Verify "Unlinked" banner when contact deleted

**Steps:**
1. Open Contacts.app
2. Delete Harvey Snodgrass's contact
3. Return to SAM
4. Navigate to People → Harvey Snodgrass

**Expected Display:**
```
Harvey Snodgrass
Client

⚠️ Contact Not Found
   This person's contact was deleted or moved.
   [Options]
   
[Only SAM-owned sections visible]
[No Family/Contact/Professional sections]
```

**Pass Criteria:**
- ✅ Orange "Unlinked" banner appears
- ✅ Options button present
- ✅ Click Options → Shows Archive/Resync/Cancel
- ✅ Click "Archive" → Harvey removed from list
- ✅ No crashes when contact missing

**If Banner Doesn't Appear:**
- Check `loadContactData()` validation logic
- Verify `contactWasInvalidated` flag set
- Check console for validation errors

---

### Test 9: Tap-to-Action Buttons

**Goal:** Verify Contact Info actions work

**Prerequisites:**
- Harvey has phone/email/address in Contacts.app

**Steps:**
1. Navigate to Harvey's detail
2. In Contact Info section:
   - Click phone icon → Should open Phone app (or show tel:// handler)
   - Click email icon → Should open Mail.app with new message
   - Click map icon → Should open Maps.app with address

**Pass Criteria:**
- ✅ Phone icon opens dialer
- ✅ Email icon opens Mail.app
- ✅ Map icon opens Maps.app
- ✅ URLs open in browser
- ✅ All actions work without errors

**If Actions Don't Work:**
- Check URL scheme handlers available
- Verify macOS version supports tel:// (may require FaceTime)
- Check NSWorkspace.shared.open() calls

---

### Test 10: AI Summary Generation

**Goal:** Verify AI summary draft and write to Contacts

**Steps:**
1. Navigate to Harvey's detail
2. Scroll to Summary Note section
3. Click [✨ Suggest AI Update]
4. **Sheet opens** with AI-generated draft
5. Edit text (optional)
6. Click "Add to Contacts"
7. Open Contacts.app → Harvey's contact → Notes field

**Expected:**
```
[Sheet]
AI-Generated Summary

Review and edit before adding...

[Editable text area with draft]

[Cancel] [Add to Contacts]

[After adding]
✅ Updated in Contacts.app
---
[New summary text appended]
```

**Pass Criteria:**
- ✅ Draft generated (even if placeholder)
- ✅ User can edit text
- ✅ "Add to Contacts" writes to CNContact.note
- ✅ Separator (---) between old and new notes
- ✅ Visible immediately in Contacts.app

---

## 🐛 Common Issues & Solutions

### Issue: "Contact Not Found" on valid contact
**Solution:** 
- Verify contactIdentifier valid (check in Contacts.app)
- Run cache refresh manually (restart app)
- Check Contacts permission granted

### Issue: Sheet doesn't open when clicking "Add to Family"
**Solution:**
- Check `AddRelationshipSheet.swift` in build target
- Verify `NoteArtifactDisplay` updated with sheet logic
- Look for compile errors in console

### Issue: Success banner appears but William not in Contacts
**Solution:**
- Check Contacts write permission granted
- Verify Harvey's contact not read-only
- Look for CNSaveRequest errors in console
- Try manual write in Contacts.app to test

### Issue: Family section empty despite contact having relations
**Solution:**
- Verify contact has `contactRelations` set
- Check `CNLabelContactRelationChild` vs custom labels
- Try adding relation manually in Contacts.app first
- Verify fetch keys include `CNContactRelationsKey`

### Issue: Cache never refreshes
**Solution:**
- Check `refreshAllCaches()` completes (console log)
- Verify modelContext configured correctly
- Try force refresh (restart app)
- Check for SwiftData save errors

---

## ✅ Full Test Pass Criteria

**All tests passed when:**
- [ ] App launches without crashes
- [ ] ContactSyncService configured on startup
- [ ] Person detail shows Family/Contact/Professional sections
- [ ] Note extraction identifies dependents correctly
- [ ] "Add to Family" sheet opens with editable fields
- [ ] CNContact write succeeds (visible in Contacts.app)
- [ ] William appears in Harvey's Family section in SAM
- [ ] Custom relationship labels accepted and displayed
- [ ] Orphaned contact banner appears when contact deleted
- [ ] Tap-to-action buttons work (call, email, maps)
- [ ] AI summary generation and write works

**If all pass:** Phase 5 implementation is **COMPLETE** ✅

**If any fail:** Check corresponding section above for troubleshooting

---

## 📊 Performance Benchmarks

**Acceptable Performance:**
- App launch → ContactSyncService configured: < 1 second
- Cache refresh (100 people): < 5 seconds
- Person detail load (single contact): < 2 seconds
- CNContact write (add relation): < 1 second
- Sheet open/close: Instant (no lag)

**If performance issues:**
- Check cache strategy (should use cached fields for lists)
- Verify lazy loading (not fetching all contacts upfront)
- Profile with Instruments if refresh > 10 seconds

---

## 🎯 Next Steps After Testing

### If All Tests Pass:
1. ✅ Mark Phase 5 complete in `context.md`
2. ✅ Create changelog entry
3. ✅ Update roadmap with Phase 6 priorities
4. ✅ Consider: Settings tab for Contacts sync preferences
5. ✅ Consider: iOS companion app (shares same Contacts)

### If Tests Fail:
1. Document failures in detail
2. Check console for specific errors
3. Review affected code sections
4. Fix and retest
5. Don't proceed to Phase 6 until stable

---

**Ready to test!** 🧪

Follow this guide step-by-step and note any issues. The goal is to verify the complete flow works end-to-end before moving to Phase 6 (AI Assistant features).
