# SAM UX Improvement Plan
**Created:** February 8, 2026  
**Based on:** Real-world testing feedback

---

## User Feedback Summary

1. **Me Card** - Not marked in people list; need special badge for app owner/agent
2. **Note Processing Indicator** - Current gray bar too subtle; needs attention-grabbing treatment
3. **Spouse & Dates** - Family relationships (spouse) and important dates (birthday, anniversary) not displayed
4. **Life Event Detection** - No frictionless popup when AI detects life events (e.g., marriage mention)
5. **Badge System** - Awareness and People tabs need badges for action items (like Inbox)
6. **Attention Management** - Need cohesive system for presenting insights based on user context

---

## Industry Best Practices Research

### Key Principles from Financial Advisor CRMs:
1. **Contextual Intelligence** - Information appears where the advisor is working
2. **Progressive Disclosure** - Critical items immediately, detailed items on demand
3. **Action-Oriented Design** - Every insight has a clear next step
4. **Relationship Timeline** - Chronological view of all touchpoints
5. **Life Event Triggers** - Automatic detection with suggested actions
6. **Compliance-First** - All communications tracked and auditable

---

## Implementation Phases

### Phase 1 (This Week) - High Impact, Medium Effort ⬅️ **CURRENT**

#### 1.1 Note Processing Indicator Enhancement
**Current:** Subtle gray bar at bottom of note sheet  
**Target:** Prominent orange card with animation and context

**Design Specs:**
- Light orange background (`orange.opacity(0.1)`)
- Orange border (`orange.opacity(0.3)`, 1px)
- Animated slide-up from bottom with fade-in
- Shows progress spinner + descriptive text
- Message: "Analyzing note with AI..." + "Looking for insights and action items"

**Files to modify:**
- Create: `NoteProcessingIndicator.swift` (new reusable component)
- Modify: `AddNoteSheet.swift` or equivalent note input view
- Add transition animations

**Estimated time:** 2-3 hours

---

#### 1.2 Badge System for Tabs
**Current:** Only Inbox has blue badge with count  
**Target:** Awareness shows actionable insights count, People shows unlinked count

**Implementation:**
```swift
// Awareness badge
@Query(filter: #Predicate<SamInsight> { 
    $0.stateRawValue == "active" && !$0.dismissed 
})
var activeInsights: [SamInsight]

var awarenessActionCount: Int {
    activeInsights.filter { $0.requiresAction }.count
}

// People badge
@Query(filter: #Predicate<SamPerson> { 
    $0.contactIdentifier == nil 
})
var unlinkedPeople: [SamPerson]
```

**Files to modify:**
- `NavigationSplitView` sidebar (likely in `AppShellView.swift` or `ContentView.swift`)
- Add `.badge()` modifiers to Awareness and People labels

**Estimated time:** 2 hours

---

#### 1.3 Me Card Badge
**Current:** User's own contact not distinguished in people list  
**Target:** "Me" badge with blue accent treatment

**Design Specs:**
- Badge text: "Me"
- Font: `.caption2.weight(.semibold)`
- Padding: horizontal 8px, vertical 3px
- Background: `.blue.opacity(0.15)`
- Foreground: `.blue`
- Corner radius: 4px
- Placement: End of person row

**Implementation Steps:**
1. Store "me card" identifier in UserDefaults
2. Auto-detect on first launch using `CNContactStore` me card
3. Add badge rendering to person list rows
4. Special treatment in detail view (suppress "Last Contact" field)

**Files to modify:**
- Settings to configure/display me card
- `PeopleListView.swift` row rendering
- `PersonDetailView.swift` (optional special treatment)

**Estimated time:** 3 hours

---

### Phase 2 (Next Week) - Critical UX

#### 2.1 In-Context Suggestions (HIGH PRIORITY)
**Problem:** Life event detected in note, but no immediate action prompt  
**Solution:** Real-time suggestion card appears in note sheet when AI finishes

**Components:**
- `SuggestionsCard.swift` - Displays detected life events with action buttons
- `LifeEventCard.swift` - Individual event with suggested actions
- `LifeEventSuggestion` data model
- Integration with note analysis pipeline

**User Flow:**
1. User adds note: "got married to Sarah on June 15"
2. AI analysis runs (orange indicator visible)
3. AI finishes → Suggestions card slides up
4. Shows: "🎊 Marriage detected: Sarah, June 15, 2024"
5. Actions: [Add Sarah] [Update Contact] [Send Congrats] [Review Coverage]
6. User clicks action → pre-filled sheet appears
7. User confirms → Contact updated

**Files to create:**
- `SuggestionsCard.swift`
- `LifeEventCard.swift`
- `LifeEventSuggestion.swift` (data models)

**Files to modify:**
- Note analysis pipeline to detect life events
- Note sheet to show suggestions card
- `ContactSyncService` for contact updates

**Estimated time:** 1-2 days

---

#### 2.2 Spouse & Important Dates Section
**Current:** Family relationships not shown  
**Target:** Display spouse, children, birthdays, anniversaries in person detail

**Data to Display:**
- **Spouse/Partner** - With link if they're in SAM
- **Birthday** - With "upcoming" indicator (within 30 days)
- **Anniversary** - With "upcoming" indicator
- **Children's birthdays** - In family section
- **Other dates** - Retirement, policy renewals

**Design:**
- Grouped section with icon labels
- Color-coded icons (heart for spouse, gift for birthday, calendar for anniversary)
- "Upcoming" badges for dates within 30 days
- Read from `CNContact.contactRelations` and `CNContact.dates`

**Files to create:**
- `FamilyAndDatesSection.swift`

**Files to modify:**
- `PersonDetailView.swift` to include new section
- `ContactSyncService` to fetch relationship data

**Estimated time:** 1 day

---

### Phase 3 (Week 3) - Polish & Cohesion

#### 3.1 Attention Management System
**Goal:** Cohesive system for surfacing insights based on user context

**Three Contexts:**

**Context 1: User actively working in sheet**
- Show suggestions in-line at bottom
- User is focused, suggestions immediately actionable

**Context 2: User navigated away**
- Badge on Awareness tab
- Don't interrupt current task

**Context 3: User opens app later**
- Awareness shows pending insights by urgency
- User is reviewing what needs attention

**Implementation:**
- `AttentionManager` singleton (ObservableObject)
- Tracks user context (which view active)
- Routes suggestions to appropriate presentation
- Manages badge counts

**Files to create:**
- `AttentionManager.swift`
- `ContextualSuggestion.swift` (data models)
- `AwarenessItem.swift` (data models)

**Estimated time:** 2-3 days

---

#### 3.2 Life Event Templates
**Goal:** Pre-defined actions for common life events

**Life Events to Support:**
- Marriage (add spouse, update contact, send congratulations, review coverage)
- Birth (add child, update beneficiaries, suggest child policy, send congratulations)
- Promotion (update job title, review retirement contributions, send congratulations)
- Retirement (review income strategy, update contact, schedule meeting)
- Home purchase (review insurance, update address, send congratulations)
- Death in family (offer condolences, review beneficiaries, schedule check-in)

**Components:**
- Template definitions with actions
- Pre-filled message templates
- Contact update templates
- Calendar event templates

**Files to create:**
- `LifeEventTemplates.swift`
- `LifeEventActions.swift`

**Estimated time:** 2 days

---

## Design System Additions

### Colors
- **Processing Indicator:** `.orange.opacity(0.1)` background, `.orange.opacity(0.3)` border
- **Suggestions Card:** `.blue.opacity(0.05)` background, `.blue.opacity(0.2)` border
- **Me Badge:** `.blue.opacity(0.15)` background, `.blue` foreground
- **Upcoming Date:** `.yellow` or `.orange` accent

### Typography
- **Badge:** `.caption2.weight(.semibold)`
- **Processing:** `.subheadline.weight(.medium)` for primary, `.caption` for secondary
- **Suggestions:** `.headline` for title, `.subheadline.weight(.medium)` for events

### Animations
- **Slide-up:** `.move(edge: .bottom).combined(with: .opacity)`
- **Duration:** Default SwiftUI spring animation
- **Timing:** Show immediately when data available

---

## Success Metrics

### Phase 1 Success Criteria:
- [ ] Note processing indicator clearly visible and attention-grabbing
- [ ] Awareness tab shows count of actionable insights
- [ ] People tab shows count of unlinked contacts
- [ ] User's contact has "Me" badge in list
- [ ] All changes maintain Swift 6 strict concurrency compliance

### Phase 2 Success Criteria:
- [ ] Life events detected from notes trigger in-context suggestions
- [ ] Suggestions appear within note sheet if user is still there
- [ ] One-click actions pre-fill contact/message sheets
- [ ] Spouse relationship visible in person detail
- [ ] Important dates shown with "upcoming" indicators

### Phase 3 Success Criteria:
- [ ] Suggestions route correctly based on user context
- [ ] Awareness tab groups insights by urgency
- [ ] Badge counts update in real-time
- [ ] Life event templates cover 6+ common scenarios
- [ ] User never loses context or gets interrupted inappropriately

---

## Technical Considerations

### SwiftData
- All new models must use raw value + @Transient pattern for enums
- Maintain proper delete order for relationships
- Use background contexts for expensive operations

### Concurrency
- All UI updates on MainActor
- ContactSyncService read methods thread-safe
- Async/await throughout, no Task.detached without careful consideration

### Permissions
- All Contacts writes respect user settings
- Feature flag for Notes entitlement (pending Apple approval)
- No surprise permission dialogs

### Performance
- Cache contact data aggressively
- Lazy load full CNContact only when needed
- Debounce AI analysis triggers

---

## Notes & Decisions

### Design Philosophy
- **Contextual over modal** - Show information where user is working
- **Action-oriented** - Every insight has a clear next step
- **Progressive disclosure** - Critical info first, details on demand
- **Respectful of attention** - Don't interrupt, use badges and indicators

### Apple HIG Alignment
- Use system colors and typography
- Standard SF Symbols for icons
- Native SwiftUI animations
- Respect Dark Mode and accessibility

---

## Next Steps

1. ✅ Create this plan document
2. ⬅️ **Phase 1.1:** Implement NoteProcessingIndicator
3. **Phase 1.2:** Add badge system to tabs
4. **Phase 1.3:** Implement Me Card badge
5. Review Phase 1 with user before proceeding to Phase 2

---

**Last Updated:** February 8, 2026  
**Status:** Phase 1 In Progress
