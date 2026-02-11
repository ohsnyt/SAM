# Phase G Complete: Contexts

**Date**: February 11, 2026  
**Status**: ✅ Complete

---

## Summary

Phase G implements context management for SAM, allowing users to organize people into **households** and **businesses**. Contexts provide the foundation for managing group relationships, shared products, and collective insights in future phases.

---

## What Was Built

### 1. ContextsRepository (Repositories/ContextsRepository.swift)

**Purpose**: SwiftData CRUD operations for SamContext

**Key Methods**:
- `fetchAll()` - Get all contexts sorted by name
- `fetch(id:)` - Get single context by UUID
- `create(name:kind:)` - Create new context
- `update(context:name:kind:)` - Update existing context
- `delete(context:)` - Remove context
- `search(query:)` - Find contexts by name
- `filter(by:)` - Filter contexts by kind (household/business)
- `addParticipant(person:to:roleBadges:isPrimary:note:)` - Add person to context
- `removeParticipant(person:from:)` - Remove person from context

**Architecture**:
- Singleton pattern with `shared` instance
- `configure(container:)` called at app launch
- `@MainActor` isolated (SwiftData requirement)
- `@Observable` for SwiftUI integration
- Follows same patterns as PeopleRepository and EvidenceRepository

### 2. ContextListView (Views/Contexts/ContextListView.swift)

**Purpose**: List of all contexts with filtering and search

**Features**:
- **Filter Picker**: All / Household / Business
- **Search Bar**: Find contexts by name
- **Create Button**: Sheet to create new context
- **Context Rows**: Icon, name, type, participant count, alert badges
- **Empty State**: Call-to-action when no contexts exist
- **Loading State**: Progress indicator during data fetch
- **Error State**: Retry button on failure

**User Flow**:
1. User sees list of contexts (households and businesses)
2. Can filter to show only one type
3. Can search by name
4. Click "+" to create new context
5. Click row to view detail

### 3. ContextDetailView (Views/Contexts/ContextDetailView.swift)

**Purpose**: View and manage a single context

**Sections**:
- **Header**: Icon, name, type, participant count, alert badges
- **Participants**: List of people in this context with roles and notes
- **Products**: Placeholder for future product management
- **Insights**: Placeholder for Phase I (AI-generated insights)
- **Metadata**: Context ID and type

**Actions**:
- **Edit**: Change context name and type (sheet)
- **Add Person**: Add participant with roles (sheet)
- **Delete**: Remove context with confirmation

**Participant Display**:
- Photo thumbnail or generic icon
- Name with "PRIMARY" badge if `isPrimary = true`
- Role badges (e.g., "Client", "Primary Insured")
- Optional note in italic text

### 4. Integration with AppShellView

**Changes**:
- Added `selectedContextID: UUID?` state for navigation
- Updated three-column layout to include "contexts"
- Added `ContextListView` to middle column
- Added `ContextsDetailContainer` for detail column
- Removed `ContextsPlaceholder` (no longer needed)

**Navigation Pattern**:
```
Sidebar: "Contexts" selected
   ↓
Middle Column: ContextListView (filtered list)
   ↓
Detail Column: ContextDetailView (selected context)
```

### 5. Supporting Components

**CreateContextSheet**:
- Name text field
- Type picker (Household / Business)
- Create button with validation
- Cancel button

**EditContextSheet**:
- Pre-filled name and type
- Save button with validation
- Cancel button

**AddParticipantSheet**:
- Person picker (excludes people already in context)
- Role badges text field (comma-separated)
- Primary participant toggle
- Optional note field
- Add button with validation

**ContextKind Extensions**:
```swift
extension ContextKind {
    var displayName: String  // "Household" or "Business"
    var icon: String         // SF Symbol name
    var color: Color         // Blue for household, purple for business
}
```

---

## Architecture Decisions

### 1. Participant Management

**Design**: ContextParticipation is a join model between SamPerson and SamContext

**Fields**:
- `person: SamPerson?` - Who participates
- `context: SamContext?` - In which context
- `roleBadges: [String]` - Roles within the context
- `isPrimary: Bool` - Primary participant (for sorting/display)
- `note: String?` - Context-specific notes
- `startDate: Date` - When participation started
- `endDate: Date?` - When it ended (nil = current)

**Why This Works**:
- Same person can be in multiple contexts with different roles
- Roles are flexible strings (not hardcoded enum)
- Primary flag lets UI prioritize display
- Notes field allows context-specific annotations

### 2. Three-Column Layout Consistency

**Pattern Established in Phase D (People) and Phase F (Inbox)**:
```
Sidebar → List View → Detail View
```

**Applied to Contexts**:
- Sidebar: "Contexts" navigation link
- List: ContextListView with filter/search
- Detail: ContextDetailView with participants

**Benefits**:
- Consistent navigation UX across all sections
- Users don't have to learn new patterns
- Code reuse (detail container pattern)
- Predictable behavior

### 3. UUID-Based Selection

**Lesson from Phase D Navigation Bug**:
SwiftData models as selection binding can cause incorrect detail views after data updates.

**Solution**:
```swift
@State private var selectedContextID: UUID?  // ✅ Use primitive ID
// NOT: @State private var selectedContext: SamContext?  ❌
```

**Detail Container Pattern**:
```swift
private struct ContextsDetailContainer: View {
    let contextID: UUID
    @Query private var allContexts: [SamContext]
    
    var context: SamContext? {
        allContexts.first(where: { $0.id == contextID })
    }
    
    var body: some View {
        if let context = context {
            ContextDetailView(context: context)
                .id(contextID)  // Force recreation on selection change
        } else {
            ContentUnavailableView(...)
        }
    }
}
```

**Why This Works**:
- SwiftUI can reliably track primitive IDs
- @Query provides fresh model reference on each update
- `.id(contextID)` forces view recreation when selection changes
- No stale model references

---

## What This Enables

### Immediate Value

**Household Management**:
- Group family members into households
- Track who's the primary insured, spouse, children
- Add household-specific notes (e.g., "Trust established 2023")

**Business Relationships**:
- Organize business contacts by company
- Track decision makers, employees, partners
- Add business-specific notes (e.g., "Annual renewal in Q4")

**Role Clarity**:
- Same person can have different roles in different contexts
- Clearly identify primary contact in each context
- Flexible role naming (not constrained to predefined options)

### Future Phases Unblocked

**Phase H (Notes)**:
- Notes can link to contexts: "Smith family trust review" → links to "Smith Family" context
- AI can analyze context-level notes

**Phase I (Insights)**:
- Generate household-level insights: "Smith family has 3 members, 2 with no life insurance"
- Generate business insights: "Acme Corp has 5 employees, 3 nearing retirement age"

**Phase K (Time Tracking)**:
- Track time spent on household planning meetings
- Track time spent on business client calls
- Report time by context

**Product Management (Future)**:
- Products can belong to contexts
- Track which households have which policies
- Track which businesses have group plans

---

## Testing & Validation

### Previews Created

1. **ContextListView**:
   - "With Contexts": Shows 3 sample contexts (2 households, 1 business)
   - "Empty": Shows empty state with call-to-action

2. **ContextDetailView**:
   - "Household with Participants": Smith Family with 2 participants (roles, primary badge)
   - "Business Context": Acme Corp with no participants

### Manual Testing Checklist

- [x] Create household context
- [x] Create business context
- [x] Add participant to context
- [x] Assign roles to participant
- [x] Mark participant as primary
- [x] Add note to participant
- [x] Edit context name
- [x] Edit context type
- [x] Delete participant
- [x] Delete context
- [x] Filter by household
- [x] Filter by business
- [x] Search contexts by name
- [x] Navigate from list to detail
- [x] Empty state displays correctly
- [x] Loading state displays correctly

---

## Files Created

```
SAM_crm/SAM_crm/
├── Repositories/
│   └── ContextsRepository.swift        ✅ NEW (228 lines)
│
└── Views/
    └── Contexts/
        ├── ContextListView.swift       ✅ NEW (370 lines)
        └── ContextDetailView.swift     ✅ NEW (520 lines)
```

**Total**: 3 new files, 1,118 lines of code

---

## Files Modified

```
SAM_crm/SAM_crm/
├── App/
│   └── SAMApp.swift                    🔧 MODIFIED
│       └── Added ContextsRepository.shared.configure(container:)
│
├── Views/
│   ├── AppShellView.swift              🔧 MODIFIED
│   │   ├── Added selectedContextID state
│   │   ├── Updated three-column layout condition
│   │   ├── Added ContextListView to content
│   │   ├── Added contextsDetailView
│   │   ├── Added ContextsDetailContainer
│   │   └── Removed ContextsPlaceholder
│   │
│   └── Settings/
│       └── SettingsView.swift          🔧 MODIFIED
│           ├── Updated feature status: Contexts → complete
│           └── Updated version: Phase G Complete
│
└── 1_Documentation/
    ├── context.md                      🔧 MODIFIED
    │   ├── Updated last modified date
    │   ├── Moved Phase G to completed
    │   └── Updated project structure
    │
    └── changelog.md                    🔧 MODIFIED
        └── Added Phase G completion entry
```

---

## Metrics

**Lines of Code**:
- New code: 1,118 lines
- Modified code: ~150 lines
- Total: ~1,268 lines

**Time to Implement**:
- Phase G planning: Review architecture, design patterns
- ContextsRepository: Following PeopleRepository pattern
- ContextListView: Following PeopleListView pattern
- ContextDetailView: Custom design for participants
- Integration: AppShellView, SAMApp configuration
- Documentation: context.md, changelog.md updates

**Patterns Followed**:
- ✅ Repository singleton pattern
- ✅ Three-column navigation
- ✅ UUID-based selection
- ✅ Sheet-based creation/editing
- ✅ Confirmation dialogs for destructive actions
- ✅ Loading/empty/error states
- ✅ Preview-driven development

---

## Next Steps

### Phase H: Notes & Note Intelligence

**Goal**: User-created notes with on-device LLM analysis

**Key Features**:
1. **Notes CRUD**:
   - Create freeform notes
   - Link to people, contexts, evidence
   - Edit and delete notes

2. **LLM Analysis** (Apple Foundation Models):
   - Extract mentioned people
   - Identify topics
   - Generate action items
   - Create summary

3. **Action Items**:
   - "Update contact" → Suggest adding birthday, spouse, child, etc.
   - "Send message" → Draft congratulations, reminder, follow-up
   - "Schedule meeting" → Create calendar event
   - "General follow-up" → Add to todo list

4. **Integration**:
   - Notes appear in PersonDetailView
   - Notes appear in ContextDetailView
   - Notes appear in InboxDetailView (attach note to evidence)
   - Notes generate evidence items for Inbox

**Example Note**:
```
Met with John and Sarah Smith. New baby Emma born Jan 15.
Sarah's mother Linda Chen interested in LTC. John promoted
to VP at Acme Corp. Want to increase life coverage.
Follow up in 3 weeks.
```

**LLM Extraction**:
- **People**: John Smith (client), Sarah Smith (spouse), Emma Smith (child, birthday Jan 15), Linda Chen (prospect, mother of Sarah)
- **Topics**: life insurance, long-term care insurance, family planning
- **Action Items**:
  - Send congratulations to John and Sarah on new baby (urgency: soon)
  - Update John's contact: new child Emma, company Acme Corp, title VP
  - Reach out to Linda Chen about LTC (urgency: standard)
  - Schedule follow-up with Smith family in 3 weeks (urgency: standard)

**Why This Matters**:
- Notes are the richest source of relationship intelligence
- Financial advisors take notes after every interaction
- Manual data entry is time-consuming and error-prone
- LLM can extract structured data from freeform text
- All processing happens on-device (privacy-first)

---

## Lessons Learned

### 1. Consistency Compounds

Following established patterns made implementation smooth:
- Copied PeopleRepository → renamed to ContextsRepository → adjusted for SamContext
- Copied PeopleListView → renamed to ContextListView → added filter picker
- Copied AppShellView people section → adapted for contexts
- Result: No architectural surprises, fast implementation

### 2. Participant Management Complexity

Initial design considered storing participants as array in SamContext. Switched to ContextParticipation join model because:
- Needs bidirectional navigation (person → contexts, context → people)
- Needs per-context metadata (role, primary flag, note)
- Needs temporal tracking (start/end dates)
- Join model provides all of this elegantly

### 3. Preview-Driven Development

Creating previews first forced thinking through:
- What sample data is needed?
- What should the empty state look like?
- What happens when data is missing?
- How should relationships display?

Result: Better UX decisions, fewer bugs

### 4. Three-Column Layout Scales Well

Adding Contexts to the three-column layout was trivial:
- Added context case to `threeColumnContent` switch
- Added context case to `threeColumnDetail` switch
- Created detail container following exact same pattern
- No changes to sidebar or navigation logic

Result: Scalable navigation architecture

---

## Documentation Updates

- ✅ `context.md` updated with Phase G completion
- ✅ `changelog.md` updated with Phase G entry
- ✅ `SettingsView.swift` feature status updated
- ✅ This completion document created

---

**Phase G Status**: ✅ **COMPLETE**

**Next Phase**: H (Notes & Note Intelligence)

**Date Completed**: February 11, 2026
