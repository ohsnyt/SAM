# Next Steps — Prioritized Roadmap

**Last Updated:** 2026-02-07  
**Current Phase:** Communication Integration (Phase 5)

---

## ✅ Just Completed (Feb 7, 2026)

- **Artifact Card Integration** — LLM-extracted entities now visible in Inbox
- **Signal Generation Fix** — Structured data pipeline working end-to-end
- **Insight Generation** — Opportunities properly surfaced on Person detail pages

**Result:** Notes-first intelligence is fully functional. Users can create notes, see extracted people/topics, and get insights.

---

## 🎯 Immediate Wins (1-2 days each)

### 1. Improve "Add Contact" Pre-Fill ⭐️
**Why:** Complete the entity extraction → contact creation loop  
**Effort:** 1 day  
**Value:** HIGH — Users can act on extracted people immediately

**Tasks:**
- Research CNContact URL schemes or use CNContactViewController
- Pre-populate name and relationship fields when opening Contacts
- Test on macOS (different from iOS contact creation)

**Files:**
- `InboxDetailSections.swift` — Update `NoteArtifactDisplay.onCreateContact`
- Consider new `ContactCreationHelper.swift` for reusable logic

---

### 2. Add Email Extraction to LLM Prompt ⭐️
**Why:** Enables full contact creation with communication channels  
**Effort:** 4-6 hours  
**Value:** MEDIUM — Nice-to-have for complete contact records

**Tasks:**
- Update `NoteLLMAnalyzer` prompt to extract email addresses
- Add `email: String?` to `StoredPersonEntity`
- Update JSON encoding/decoding in `SamAnalysisArtifact`
- Pass email to contact creation flow

**Files:**
- `NoteLLMAnalyzer.swift` — Update prompt text
- `SamAnalysisArtifact.swift` — Update `StoredPersonEntity` struct
- `InboxDetailSections.swift` — Pass email to `onSuggestCreateContact`

---

### 3. Display Topics as Visual Tags in Header ⭐️
**Why:** At-a-glance visibility of conversation themes  
**Effort:** 3-4 hours  
**Value:** MEDIUM — Complements the detailed card view

**UI:**
```
[Title] 📝 Feb 7, 2026
[Life Insurance] [Retirement] [IRA]  ← NEW
```

**Tasks:**
- Parse `artifact.topics` in `HeaderSection`
- Render as colored chips (SF Symbols + rounded rectangles)
- Color-code by sentiment (green=wants, blue=considering, red=cancel)

**Files:**
- `InboxDetailSections.swift` — Update `HeaderSection.body`
- Consider extracting `TopicChip` as reusable component

---

## 📬 Communication Integration (1-2 weeks)

### 4. Mail Integration Foundation ⭐️⭐️⭐️
**Why:** Most common communication channel; scale note intelligence to emails  
**Effort:** 1 week  
**Value:** VERY HIGH — Automates evidence creation from daily workflow

**Approach:**
1. **Account Selection UI** (Settings)
   - User designates single "SAM work account"
   - Store account identifier in UserDefaults
   - Show account name and status in Settings

2. **Mail Observer** (Background)
   - Use Mail.app scripting bridge or EventKit-like observer
   - Fetch new messages from designated account only
   - Extract envelope data: from/to/subject/date/threadID

3. **Analysis Pipeline** (Reuse existing)
   - Pass message body to `MailMessageAnalyzer` (clone of `NoteLLMAnalyzer`)
   - Generate `SamAnalysisArtifact` with extracted entities
   - Create `SamEvidenceItem` with source=`.email`
   - **Never persist raw email body** (store summary only)

4. **UI Integration**
   - Show email-based evidence in Inbox (same as notes)
   - Display sender/recipient in Participants section
   - Link to Mail.app via message:// URL scheme

**New Files:**
- `MailImportCoordinator.swift` — Observes Mail account
- `MailMessageAnalyzer.swift` — Analyzes email content
- `SamMailMessage.swift` — @Model for metadata storage
- `MailEvidenceFactory.swift` — Creates evidence from emails

**Privacy Constraints:**
- Only access user-designated account
- Store metadata + analysis artifacts, not raw bodies
- User can disable mail integration in Settings

---

### 5. Calendar Deep Integration (Two-Way) ⭐️⭐️
**Why:** Make SAM proactive, not just reactive  
**Effort:** 2-3 days  
**Value:** HIGH — Closes the loop on calendar integration

**Features:**
1. **"Schedule Meeting" Action**
   - Button on Person/Context detail page
   - Opens Calendar.app with attendees pre-filled
   - Creates event in SAM calendar
   - Links event → Evidence → Person

2. **Meeting Prep Assistant**
   - Notification 1 hour before meeting
   - Popover/sheet with attendee details
   - Surface relevant insights for each attendee
   - "Recent interactions" summary
   - Quick actions: view person detail, draft follow-up

**Files to Modify:**
- `CalendarImportCoordinator.swift` — Add `createEvent()` method
- `PersonDetailView.swift` — Add "Schedule Meeting" button
- New: `MeetingPrepView.swift` — Pre-meeting assistant

**Permissions:**
- Reuse existing calendar authorization (already granted)
- Write events to SAM calendar only (no other calendars)

---

## 🤖 AI Assistant (2-3 weeks)

### 6. Proactive Relationship Nudges ⭐️⭐️⭐️
**Why:** Make SAM feel like a "thoughtful junior partner"  
**Effort:** 1 week  
**Value:** VERY HIGH — Core value proposition

**Implementation:**
- Daily background scan for:
  - People with no evidence in 30/60/90 days
  - Contexts with stale "last interaction" dates
  - Upcoming birthdays/anniversaries (from Contacts)
  - Unresolved consent requirements
  - Pending follow-up actions
- Generate `SamInsight` with category `.neglectedRelationship` or `.upcomingEvent`
- Surface in Awareness → "Needs Attention"

**New Types:**
```swift
enum InsightCategory {
    case neglectedRelationship(daysSince: Int)
    case upcomingEvent(EventType, daysUntil: Int)
    case missingConsent(ConsentType)
    // ... existing cases
}
```

**UI:**
```
⚠️ Needs Attention
┌─────────────────────────────────────
│ You haven't connected with John Smith in 45 days
│ Last interaction: Dec 23 (Holiday Party)
│ [View Person] [Schedule Follow-Up]
└─────────────────────────────────────
```

---

### 7. Communication Drafting Assistant ⭐️⭐️
**Why:** Reduce friction for follow-ups; always user-controlled  
**Effort:** 1 week  
**Value:** HIGH — Users want output, not just analysis

**Features:**
- "Draft Follow-Up" action in Evidence detail
- Pass context to LLM:
  - Person details (name, last interaction date)
  - Meeting/note content (via `SamAnalysisArtifact`)
  - Relevant insights
  - Financial topics discussed
- Generate email draft → preview sheet → user edits
- Actions: [Copy to Clipboard] [Open in Mail]

**UI Flow:**
```
Evidence Detail
  ↓ Click [Draft Follow-Up]
Sheet with:
  - Editable TextEditor (pre-filled)
  - To: [Person Name] <email>
  - Subject: [Generated]
  - Body: [AI-drafted text]
  
  [Cancel] [Copy] [Open in Mail]
```

**Safety:**
- Never send automatically
- Always show full preview
- User must explicitly copy or open Mail
- Log all generated drafts for compliance

---

## 🎨 Quick Wins: UX Polish (few hours each)

### 8. Add Notes to "Recent Interactions" ⭐️
**Where:** Person detail page  
**What:** List `SamNote` items alongside calendar events  
**Why:** Users expect to see their notes in interaction history

**Current:**
```
Recent Interactions
- 📅 Feb 5: Meeting with John
- 📅 Jan 28: Phone call
```

**After:**
```
Recent Interactions
- 📝 Feb 7: Note about William's life insurance
- 📅 Feb 5: Meeting with John
- 📅 Jan 28: Phone call
```

---

### 9. Keyboard Shortcuts Audit ⭐️
**Current gaps:**
- `⌘N` for "Add Note" (currently only button)
- `⌘K` for quick person search
- `⌘1/2/3/4` for sidebar navigation (Awareness/People/Contexts/Inbox)

**Implementation:**
```swift
// In SAMApp.swift
.commands {
    CommandGroup(after: .newItem) {
        Button("Add Note") { /* ... */ }
            .keyboardShortcut("n", modifiers: .command)
    }
    
    CommandGroup(after: .sidebar) {
        Button("Awareness") { /* ... */ }
            .keyboardShortcut("1", modifiers: .command)
        // etc.
    }
}
```

---

### 10. Empty State Improvements ⭐️
**Where:** Inbox, People list, Contexts list  
**What:** Helpful illustrations and quick actions

**Inbox (empty):**
```
📥

No evidence to review

Your inbox is clear! Add a note or import
calendar events to start building awareness.

[Add Note] [Import Calendar]
```

**People (empty):**
```
👥

No people yet

Import contacts from your address book or
add people manually as you interact.

[Import Contacts] [Add Person]
```

---

## 🚀 My Recommendation: Next Sprint

### Week 1 (Quick Wins)
1. ✅ Improve "Add Contact" pre-fill (1 day)
2. ✅ Add email extraction to LLM prompt (4-6 hours)
3. ✅ Display topics as tags in header (3-4 hours)
4. ✅ Add notes to Recent Interactions (2-3 hours)

**Outcome:** Polish the notes-first experience before scaling to email.

---

### Week 2-3 (Mail Integration)
5. ✅ Mail account selection UI (1 day)
6. ✅ Mail observer + metadata storage (2 days)
7. ✅ Mail analysis pipeline (1 day)
8. ✅ Email-based evidence in Inbox UI (1 day)

**Outcome:** Automated evidence from email (most common channel).

---

### Week 4 (Calendar Two-Way)
9. ✅ "Schedule Meeting" action (1 day)
10. ✅ Meeting prep assistant (2 days)

**Outcome:** Proactive meeting support; closes calendar loop.

---

### Phase 6 (AI Assistant) — 2-3 Weeks
11. ✅ Proactive relationship nudges (1 week)
12. ✅ Communication drafting assistant (1 week)
13. ✅ UX polish + keyboard shortcuts (few days)

**Outcome:** SAM feels like a "thoughtful junior partner."

---

## 📊 Success Metrics

**Phase 5 (Communication Integration):**
- [ ] 90%+ of user interactions (meetings, emails, notes) automatically captured
- [ ] Evidence requires < 30 seconds to triage (accept/decline links)
- [ ] Zero surprise permission dialogs
- [ ] Contact creation from extracted people works in < 3 taps

**Phase 6 (AI Assistant):**
- [ ] Users receive 3-5 actionable nudges per week
- [ ] Draft follow-ups used in 50%+ of post-meeting workflows
- [ ] Relationship health scores visible on all active people
- [ ] Zero autonomous actions (all AI suggestions require approval)

---

## 🛠 Technical Debt to Address

### High Priority
1. **Concurrency warnings** (DevLogStore.shared, actor isolation)
2. **SwiftData query performance** at scale (1000+ people)
3. **Backup/restore flow** for Mail metadata

### Medium Priority
4. **Accessibility audit** (VoiceOver, Dynamic Type, Reduced Motion)
5. **Design system** (consistent spacing, typography, color tokens)
6. **Unit tests** for LLM prompt consistency

### Low Priority (deferred)
7. **iOS companion app** (Phase 8)
8. **Zoom transcript integration** (Phase 6)
9. **Natural language commands** ("Show me everyone I need to call this week")

---

## Questions to Resolve

1. **Mail API Strategy:**
   - Use Mail.app scripting bridge (AppleScript)?
   - Use private MailKit framework (if available)?
   - Use IMAP direct access (requires user IMAP settings)?

2. **Contact Pre-Fill:**
   - CNContactViewController (in-app editing)?
   - URL scheme parameters (if supported)?
   - AppleScript to Contacts.app?

3. **LLM Prompt Evolution:**
   - When to add more entity types (locations, dates, amounts)?
   - How to handle multi-language notes?
   - When to switch from heuristic fallback to LLM-only?

4. **Insight Lifecycle:**
   - When to auto-dismiss insights (after user acts)?
   - How to surface "stale" insights vs. "active" ones?
   - Should insights have explicit expiration dates?

---

**Ready to start Week 1?** Let me know which task you'd like to tackle first! 🚀
