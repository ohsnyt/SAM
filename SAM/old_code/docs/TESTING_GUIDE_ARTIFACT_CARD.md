# Testing Guide: AnalysisArtifactCard Integration

**Date:** 2026-02-07  
**Feature:** LLM-extracted entities display in Inbox detail view

---

## Prerequisites

- SAM app built and running on macOS
- Database contains at least one note with LLM analysis
- Inbox view accessible from sidebar

---

## Test Scenario 1: View Extracted Entities

### Setup
1. Launch SAM
2. Click "Add Note" from Inbox toolbar (or any view)
3. Enter test note:
   ```
   I just had a son. His name is William. 
   I want little Willie to have a $60,000 life insurance policy.
   ```
4. Select a person (or leave unlinked)
5. Click "Save"

### Expected Behavior
1. **Note saves** → Evidence item created (state=needsReview)
2. **Analysis runs** → `SamAnalysisArtifact` generated
3. **Inbox updates** → New item appears in list
4. **Select item** → Detail view opens

### Verification Checklist
- [ ] **Analysis Card appears** between header and evidence sections
- [ ] **Card header shows:**
  - "AI Analysis" label with brain icon
  - Badge: "On-Device LLM" or "Heuristic"
- [ ] **Collapsible sections present:**
  - People (2) — collapsed by default
  - Financial Topics (1) — collapsed by default
  - Facts — if extracted
  - Implications (2) — collapsed by default
- [ ] **Card has rounded corners** and subtle background color
- [ ] **No console errors** or SwiftData crashes

---

## Test Scenario 2: Expand/Collapse Sections

### Action
1. Click "People (2)" section header

### Expected
- Section **expands** to show:
  ```
  William (son) [NEW] [➕ Add Contact]
    Also: Willie
  Advisor (Financial Advisor)
  ```
- Chevron icon changes from **right** (›) to **down** (∨)

### Action
2. Click "People (2)" again

### Expected
- Section **collapses** (content hidden)
- Chevron icon changes from down to right

### Verification
- [ ] Click triggers expansion/collapse
- [ ] Animation is smooth (no flicker)
- [ ] Other sections remain in their state (independent)
- [ ] Can expand multiple sections simultaneously

---

## Test Scenario 3: "Add Contact" Action

### Action
1. Expand "People" section
2. Click **➕ Add Contact** button next to "William (son)"

### Expected Behavior
1. **Contacts.app launches** (macOS)
2. **New contact window** may open (depends on macOS version)
3. **No crash** in SAM app
4. **No error alerts** displayed

### Current Limitations (Expected)
⚠️ **Pre-fill not yet implemented:**
- Contacts.app opens but fields are **empty**
- User must **manually type** name and details
- This is expected behavior at this stage

### Verification
- [ ] Clicking button **doesn't crash** the app
- [ ] Contacts.app **successfully launches**
- [ ] SAM app remains **responsive** after action
- [ ] No error messages in console about missing email

### Next Steps (Post-Integration)
- Enhancement: Pre-fill name fields via URL scheme or CNContact API
- Add email extraction to LLM prompt
- Pass email to contact creation flow

---

## Test Scenario 4: Financial Topics Display

### Setup
Same note as Scenario 1

### Action
1. Expand "Financial Topics (1)" section

### Expected
```
Life Insurance
  $60,000
  For: William
  Sentiment: wants (green color)
```

### Verification
- [ ] **Product type** displays with appropriate icon (cross.case for life insurance)
- [ ] **Amount** shown in blue, bold font
- [ ] **Beneficiary** name matches extracted person
- [ ] **Sentiment** color-coded:
  - Green = wants/interest
  - Blue = increase
  - Orange = considering
  - Red = not interested/cancel

---

## Test Scenario 5: Calendar Events (No Card)

### Setup
1. Import a calendar event into SAM calendar
2. Ensure event appears in Inbox

### Action
1. Select calendar-based evidence item

### Expected
- **Header section** appears (with event details)
- **NO Analysis Card** displayed (calendar events don't have artifacts)
- **Evidence section** shows event description
- **Participants section** shows attendees
- **Signals section** shows detected signals

### Verification
- [ ] Analysis card **only appears for notes** (source=.note)
- [ ] Calendar events display normally **without card**
- [ ] No errors or empty card placeholders

---

## Test Scenario 6: Note Without LLM Data

### Setup
1. Create a very short note (e.g., "Test")
2. LLM may not extract entities (empty artifact)

### Expected
- **Card may not appear** (if no artifact created)
- OR **Card appears with "Heuristic" badge** and minimal data
- **No crash** due to missing data

### Verification
- [ ] App gracefully handles notes without analysis
- [ ] Empty sections are **hidden** (not shown as empty)
- [ ] No "undefined" or null values displayed
- [ ] User can still interact with note (mark done, link, etc.)

---

## Test Scenario 7: Multiple Notes in Inbox

### Setup
1. Create 3 different notes with varying content
2. Ensure all appear in Inbox list

### Action
1. Click first note → verify card displays
2. Click second note → verify card updates
3. Click third note → verify card updates

### Expected
- **Card content changes** when selecting different notes
- **No stale data** from previous selection
- **SwiftData query updates** correctly
- **Smooth transitions** between selections

### Verification
- [ ] Selecting different notes updates the card
- [ ] No flickering or delayed updates
- [ ] Correct artifact data displayed for each note
- [ ] Performance remains smooth with multiple notes

---

## Test Scenario 8: Delete Note with Artifact

### Setup
1. Create note with analysis
2. View in Inbox (card displays)

### Action
1. (If delete functionality exists) Delete the note
2. OR mark as done and archive

### Expected
- **Evidence item updates** or removes
- **No orphaned artifact** errors
- **SwiftData cascade delete** works correctly
- **Inbox list updates** smoothly

### Verification
- [ ] Deleting note doesn't crash app
- [ ] Artifact relationship handled correctly
- [ ] No console warnings about missing relationships
- [ ] Inbox UI reflects deletion immediately

---

## Edge Cases to Test

### 1. Very Long Note
**Input:** 2000+ character note with many people/topics  
**Expected:**
- Card doesn't overflow or clip
- Sections remain collapsible
- ScrollView handles long content
- Performance remains acceptable

### 2. Special Characters in Names
**Input:** Note mentioning "José García" or "O'Brien"  
**Expected:**
- Names display correctly (no encoding issues)
- Unicode characters render properly
- Contact creation handles special chars

### 3. Multiple Relationships
**Input:** "I spoke with Sarah (wife) and Tom (brother-in-law)"  
**Expected:**
- Both people extracted with relationships
- Each has "Add Contact" button
- Relationships displayed in subtitle

### 4. Ambiguous Amounts
**Input:** "We discussed $50K to $100K in coverage"  
**Expected:**
- LLM extracts one or both amounts
- Display handles range gracefully
- No parsing errors

### 5. Rapid Selection Changes
**Action:** Quickly click through 10 notes in succession  
**Expected:**
- No lag or frozen UI
- SwiftData queries keep up
- Memory usage stays reasonable

---

## Debugging Tips

### If Card Doesn't Appear
1. **Check source type:**
   ```swift
   print("Evidence source: \(item.source)")
   // Should be .note, not .calendar
   ```

2. **Check sourceUID:**
   ```swift
   print("Source UID: \(item.sourceUID ?? "nil")")
   // Should be valid UUID string
   ```

3. **Check note relationship:**
   ```swift
   if let noteID = UUID(uuidString: item.sourceUID ?? "") {
       // Query notes manually
       let notes = try? modelContext.fetch(FetchDescriptor<SamNote>(...))
       print("Found notes: \(notes?.count ?? 0)")
   }
   ```

4. **Check artifact:**
   ```swift
   if let note = notes.first {
       print("Note has artifact: \(note.analysisArtifact != nil)")
       print("Artifact people: \(note.analysisArtifact?.people.count ?? 0)")
   }
   ```

### If "Add Contact" Crashes
1. **Check ContactsImportCoordinator:**
   ```swift
   // Ensure shared store is initialized
   print("Contact store: \(ContactsImportCoordinator.contactStore)")
   ```

2. **Check permissions:**
   ```swift
   let status = CNContactStore.authorizationStatus(for: .contacts)
   print("Contacts auth: \(status)")
   // Should be .authorized (not required for opening Contacts.app)
   ```

3. **Check NSWorkspace API:**
   ```swift
   let url = URL(fileURLWithPath: "/System/Applications/Contacts.app")
   print("Contacts.app exists: \(FileManager.default.fileExists(atPath: url.path))")
   ```

### Console Output to Look For

**Successful Integration:**
```
📝 [NoteEvidenceFactory] Creating evidence for note <UUID>
📝 [NoteEvidenceFactory] Note has 1 linked people: ["Harvey Snodgrass"]
✅ [NoteEvidenceFactory] Created evidence item for note <UUID>
🧠 [NoteLLMAnalyzer] Extracted 2 people, 1 topics
📊 [ArtifactToSignalsMapper] Priority-1 mapper: Generated 1 signals from structured data
```

**Errors to Watch For:**
```
❌ Error fetching notes: <error>
❌ Failed to decode artifact JSON: <error>
❌ Contacts app could not be opened: <error>
```

---

## Acceptance Criteria

### Must Pass (Blocking)
- [ ] Card displays for note-based evidence
- [ ] Sections expand/collapse without crash
- [ ] "Add Contact" opens Contacts.app
- [ ] No crashes or data loss
- [ ] Calendar events unaffected

### Should Pass (High Priority)
- [ ] All extracted entities visible
- [ ] Color-coding and icons work
- [ ] Performance acceptable with 10+ notes
- [ ] Edge cases handled gracefully

### Nice to Have (Future)
- [ ] Pre-filled contact fields
- [ ] Email addresses extracted
- [ ] Direct link to note detail
- [ ] Export artifact data

---

## Reporting Issues

If you encounter bugs, include:
1. **Steps to reproduce** (detailed)
2. **Expected behavior**
3. **Actual behavior**
4. **Console logs** (copy relevant output)
5. **Screenshots** (if UI issue)
6. **Note content** (if privacy allows)

---

## Next Steps After Testing

1. **If all tests pass:**
   - Merge to main branch
   - Update changelog with completion
   - Move to next roadmap item (email extraction or contact pre-fill)

2. **If issues found:**
   - Create issue with reproduction steps
   - Fix critical bugs before proceeding
   - Re-test after fixes

3. **For enhancements:**
   - Add to roadmap (see NEXT_STEPS_SUMMARY.md)
   - Prioritize based on user feedback
   - Consider UX improvements (animations, hover states, etc.)

---

**Happy Testing!** 🧪

This integration lays the foundation for actionable intelligence in SAM. Once validated, we can scale the same pattern to emails, meeting transcripts, and other communication channels.
