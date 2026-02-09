# Contacts-as-Identity Architecture — Implementation Started

**Date:** 2026-02-07  
**Phase:** 5 (Contacts-Rich UI)  
**Status:** In Progress

---

## 🎯 Architecture Decision

**Philosophy:** Apple Contacts is the system of record for identity. SAM is the system of record for relationship intelligence.

### What Changed
- **Before:** SAM stored names, emails, and family data in `SamPerson`
- **After:** SAM stores only `CNContact.identifier` + cached display fields; full identity data lazy-loaded from Contacts

### Why This Matters
1. **Single source of truth:** User edits in Contacts.app sync to SAM automatically
2. **User trust:** "SAM uses my contacts" vs. "SAM creates duplicate database"
3. **System integration:** Leverage Siri, Spotlight, FaceTime, Messages, etc.
4. **Reduced maintenance:** Apple maintains identity schema, we focus on intelligence

---

## ✅ Completed (Week 1, Day 1)

### 1. ContactSyncService (Core Service Layer)

**File:** `ContactSyncService.swift`

**Capabilities:**
- ✅ Fetch full CNContact with all fields (family, contact info, dates, notes)
- ✅ Write child relationships to `CNContact.contactRelations`
- ✅ Update `CNContact.note` with AI-suggested summaries (append, don't overwrite)
- ✅ Create new CNContact for extracted people with contact info
- ✅ Cache display fields (name, email, photo) in SamPerson
- ✅ Bulk cache refresh for all people
- ✅ Check if contact exists (orphaned contact detection)

**Key Methods:**
```swift
// Fetch
func contact(for person: SamPerson) throws -> CNContact?
func contact(withIdentifier: String) throws -> CNContact?

// Write
func addChild(name: String, relationship: String?, to: SamPerson) throws
func updateSummaryNote(_ text: String, for: SamPerson) throws
func createContact(givenName:familyName:email:phone:...) throws -> String

// Cache
func refreshCache(for: SamPerson) throws
func refreshAllCaches() async throws
func contactExists(identifier: String) -> Bool
```

**Singleton Pattern:**
```swift
ContactSyncService.shared.configure(modelContext: context)
```

---

### 2. SamPerson Model Update (Migration: SAM_v5 → SAM_v6)

**File:** `SAMModels.swift`

**New Fields (Additive, Non-Breaking):**
```swift
// Cached for performance (refreshed on sync)
public var displayNameCache: String?
public var emailCache: String?
public var photoThumbnailCache: Data?
public var lastSyncedAt: Date?

// Orphaned contact handling
public var isArchived: Bool = false
```

**Deprecated Fields (Kept for Backward Compatibility):**
```swift
@deprecated Use displayNameCache
public var displayName: String

@deprecated Use emailCache
public var email: String?
```

**Migration Strategy:**
- Phase 1 (Current): Add cache fields, keep old fields
- Phase 2 (Future): Backfill caches from CNContact
- Phase 3 (SAM_v7): Remove deprecated fields

---

### 3. Person Detail UI Sections (Contacts-Rich Views)

**File:** `PersonDetailSections.swift`

**New Components:**

#### FamilySection
Displays relationships from `CNContact.contactRelations`:
- Spouse/Partner
- Children (with relationship labels: son/daughter/child)
- Parents
- Birthday (with or without year)
- Anniversary
- "Edit in Contacts" button (opens via `addressbook://` URL)

#### ContactInfoSection
Displays contact methods with tap-to-action:
- Phone numbers → Tap to call (tel:// URL)
- Email addresses → Tap to email (mailto:// URL)
- Postal addresses → Tap to open Maps
- URLs → Tap to open in browser
- All fields support text selection

#### ProfessionalSection
Displays work info:
- Company/Organization
- Job title
- Department

#### SummaryNoteSection
Displays and manages `CNContact.note`:
- Read-only display of existing note
- "Suggest AI Update" button (generates draft from insights/evidence)
- "Edit in Contacts" button
- Approval sheet for AI-generated summaries (editable before saving)

**Helper Components:**
- `RelationRow` — Family member with navigation action
- `ContactItemRow` — Contact field with tap-to-action
- `InfoRow` — Professional info display
- `AISummaryApprovalSheet` — User review of AI suggestions

---

## 📋 Contact Record Creation Rules (Documented)

Per user decision:

1. **Create CNContact only when:**
   - We contact or are contacted by someone
   - Contact information is provided (email, phone, address)

2. **For extracted dependents (children):**
   - Add to parent's `CNContact.contactRelations` (no separate contact)
   - Only create separate CNContact if contact info exists

3. **Example Flow:**
   ```
   Note: "I have a son William"
   → Add "William (son)" to Harvey's CNContact.contactRelations
   → No separate William contact created
   → William appears in Harvey's FamilySection
   ```

---

## 📋 Contact Deletion Handling (Documented)

Per user decision: **Option C (Orphan Mode with User Choice)**

When CNContact deleted externally:
1. `SamPerson.isArchived` remains `false` (don't auto-archive)
2. "Unlinked" badge appears in UI
3. User sees three options:
   - **Archive** — Remove from active views (soft delete)
   - **Resync** — Attempt to find contact again (search by cached name/email)
   - **Cancel** — Keep in limbo state, user will fix manually

**Implementation:**
```swift
// In person list view
if person.isArchived {
    // Don't display in list
} else if person.contactIdentifier != nil && !ContactSyncService.shared.contactExists(person.contactIdentifier!) {
    // Show "Unlinked" badge with Archive/Resync/Cancel options
}
```

---

## 📋 Contacts Sync Settings (Documented)

Per user decision:

**Default:** User approval required for all Contact writes

**Optional Automatic Modes (Settings → Contacts):**
- [ ] Auto-add new family members to CNContact (default: OFF)
- [ ] Auto-update CNContact summary notes (default: OFF)  
- [ ] Auto-archive SAM people when CNContact deleted (default: OFF)

**Settings UI:**
```
Settings → Contacts Tab

☐ Automatically add family members to Contacts
  When SAM extracts a child's name, add to parent's
  contact without asking for approval.

☐ Automatically update summary notes
  When SAM generates a summary, add to Contacts
  record without showing review sheet.

☐ Automatically archive deleted contacts
  When a contact is deleted from Contacts.app,
  automatically archive the person in SAM.
```

---

## 📋 Performance Strategy (Documented)

### List Views (High Performance Required)
- Use cached fields: `displayNameCache`, `emailCache`, `photoThumbnailCache`
- No CNContact fetches in list
- Smooth scrolling with 1000+ people

### Detail Views (Lazy Loading)
- Fetch full CNContact when detail view opens
- Load all sections at once (simpler than progressive loading)
- Cache result for session (avoid refetch on back/forward navigation)

### Cache Refresh Triggers
1. **App Launch:** Bulk refresh all caches in background
2. **Contacts Change Notification:** Refresh affected person's cache
3. **After Write Operation:** Immediate refresh for modified contact
4. **Manual Trigger:** Settings → "Refresh All Contacts" button

---

## 🚧 Next Steps (Week 1, Days 2-3)

### Immediate (Required for Basic Functionality)

1. **Integrate UI sections into PersonDetailView**
   - Find existing PersonDetailView implementation
   - Add lazy CNContact fetch at view open
   - Insert new sections: Family → Contact Info → Professional → Summary
   - Test with existing fixture data

2. **Update AnalysisArtifactCard action**
   - Detect dependent relationships (son/daughter/child)
   - Change "Add Contact" → "Add to Family" for dependents
   - Wire to `ContactSyncService.addChild()`
   - Show success banner on completion

3. **App Initialization**
   - Configure `ContactSyncService.shared` with modelContext
   - Run initial cache refresh (async, low priority)
   - Set up Contacts change observer (future)

### Testing Scenarios

1. **View Harvey Snodgrass detail:**
   - Verify FamilySection displays children from CNContact
   - Verify ContactInfoSection displays phone/email
   - Verify "Edit in Contacts" opens Contacts.app

2. **Extract William from note:**
   - Verify "Add to Harvey's Family" button appears
   - Click button → William added to Harvey's CNContact
   - Refresh Harvey's detail → William now appears in FamilySection

3. **AI Summary generation:**
   - Click "Suggest AI Update" in SummaryNoteSection
   - Review generated draft in approval sheet
   - Edit text → Click "Add to Contacts"
   - Open Contacts.app → Verify note appended

---

## 📊 Data Flow Diagrams

### Before (SAM as Identity Manager)
```
User creates note "I have a son William"
  ↓
Extract "William (son)"
  ↓
Create SamPerson(displayName: "William")
  ↓
Store in SAM database
  ↓
User sees William only in SAM UI
  ⚠️ Contacts.app has no knowledge of William
```

### After (Contacts as Identity Manager)
```
User creates note "I have a son William"
  ↓
Extract "William (son)"
  ↓
ContactSyncService.addChild("William", "son", to: harveyPerson)
  ↓
Write to Harvey's CNContact.contactRelations
  ↓
User sees William in:
  - Contacts.app (Harvey's family section)
  - SAM PersonDetailView (Harvey's FamilySection)
  - SAM Insights ("Life insurance for William")
  ✅ Single source of truth, synchronized everywhere
```

---

## 🎯 Success Criteria

### Week 1 Complete When:
- [ ] PersonDetailView displays family/contact info from CNContact
- [ ] "Add to Family" action writes to CNContact.contactRelations
- [ ] AI summary approval flow works end-to-end
- [ ] Cache performance acceptable (list scrolling smooth)
- [ ] No crashes or data loss with orphaned contacts

### User Experience Win:
```
Before: 6 steps, high friction
1. Create note about William
2. View in Inbox
3. Expand "People" section
4. Click "Add Contact"
5. Contacts.app opens (empty)
6. Manually type everything

After: 2 steps, zero friction
1. Create note about William
2. Click "Add to Harvey's Family" → Done
   - William appears in Harvey's CNContact
   - William visible in Contacts.app
   - SAM reads family data from Contacts
```

---

## 📝 Files Created/Modified

### Created:
- ✅ `ContactSyncService.swift` — Core sync service (singleton)
- ✅ `PersonDetailSections.swift` — UI components (Family, ContactInfo, Professional, Summary)
- ✅ `CONTACTS_ARCHITECTURE_IMPLEMENTATION.md` — This document

### Modified:
- ✅ `SAMModels.swift` — Added cache fields to SamPerson
- ✅ `context.md` — Documented Contacts-as-Identity architecture

### Next to Modify:
- [ ] `PersonDetailView.swift` — Integrate new sections
- [ ] `InboxDetailSections.swift` — Update "Add Contact" action
- [ ] `SAMApp.swift` — Configure ContactSyncService on launch
- [ ] `SamSettingsView.swift` — Add Contacts sync settings tab

---

## 🔍 Code Review Notes

### Design Decisions

1. **Why singleton for ContactSyncService?**
   - Matches pattern of other coordinators (CalendarImportCoordinator, ContactsImportCoordinator)
   - Single CNContactStore instance required (per-instance auth cache issue on macOS)
   - Simplifies dependency injection (no need to pass service through view hierarchy)

2. **Why cache in SamPerson instead of fetching on-demand?**
   - List performance: Fetching 1000 CNContacts for list view is prohibitively slow
   - Offline access: App works even without Contacts authorization (degraded mode)
   - Name formatting: CNContactFormatter handles locale-specific ordering

3. **Why append to CNContact.note instead of overwrite?**
   - User may have existing notes from Contacts.app
   - SAM-generated summaries are additive, not replacements
   - Separator (`---`) makes sections visually distinct

4. **Why lazy-load CNContact in detail view?**
   - Detail view is infrequent (user clicks on one person at a time)
   - Fetching all fields is fast enough for interactive use
   - Simpler than progressive loading (all sections render at once)

---

## ❓ Open Questions (For User)

1. **Should we support CNContact creation from AnalysisArtifactCard?**
   - Current: "Add to Family" only (for dependents)
   - Option: "Create Contact" button for adults with contact info
   - Trade-off: Simplicity vs. completeness

2. **How aggressive should cache refresh be?**
   - Current: On app launch (async, low priority)
   - Option: Real-time Contacts change observer (more complex)
   - Trade-off: Freshness vs. battery/performance

3. **Should we validate CNContact writes before executing?**
   - Current: Trust CNContactStore to reject invalid data
   - Option: Pre-validate relationships, names, etc.
   - Trade-off: Safety vs. complexity

4. **What to display when Contacts authorization denied?**
   - Current: Cached fields still work (name, email, photo)
   - Option: Show alert prompting user to grant access
   - Trade-off: Graceful degradation vs. user education

---

**Ready for Week 1, Day 2:** Integration and Testing 🚀
