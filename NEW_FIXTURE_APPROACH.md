# New Fixture Approach - Real-World Integration Testing

## Overview

The fixture seeder has been completely rewritten to demonstrate SAM's real capabilities by:
1. **Clearing all SwiftData** - Start fresh
2. **Importing from Contacts** - Use actual contact data (Harvey Snodgrass)
3. **Creating real products** - Harvey's IUL with realistic values
4. **Creating a realistic note** - About William's birth
5. **Letting SAM's pipeline work** - LLM analysis → Evidence → Insights → Suggestions

## What Gets Created

### 1. Harvey Snodgrass (from Contacts.app)
- ✅ Imported if he exists in your Contacts
- ✅ Creates `SamPerson` with contact link
- ✅ Caches display name and email

### 2. Harvey's IUL Product
```swift
Product(
    productType: .iul,
    carrier: "Sample Insurance Co.",
    policyNumber: "IUL-2024-001",
    annualPremium: 8_000.0,     // $8,000/year
    faceAmount: 30_000.0,       // $30,000 initial
    issueDate: 1 year ago,
    status: .inForce,
    owners: [harvey]
)
```

### 3. Note About William's Birth
```
I had a son born on September 17, 2023. His name is William. 
I want my young Billy to have a $50,000 life insurance policy. 
And in addition, I got a raise at work recently so I'd like to 
increase my contributions to my IUL. Can we talk about that as well?
```

## What Happens Automatically

Once the note is created, SAM's pipeline kicks in:

### 1. LLM Analysis (NoteLLMAnalyzer)
- Detects William as Harvey's son
- Extracts birth date (September 17, 2023)
- Identifies life insurance request ($50,000)
- Detects work raise
- Identifies IUL contribution increase request

### 2. Evidence Creation (NoteEvidenceFactory)
- Creates `SamEvidenceItem` for the note
- Links to Harvey
- **NEW:** Generates `ProposedLink` to suggest adding William

### 3. Signal Generation (ArtifactToSignalsMapper)
- Life event signal (birth)
- Product opportunity signal ($50,000 life insurance)
- Compliance signal (add dependent)

### 4. Smart Suggestions (SmartSuggestionCard)
When you open the evidence item, you'll see:

```
┌─────────────────────────────────────────────────┐
│ ✨ SAM Suggestions                              │
├─────────────────────────────────────────────────┤
│ 👤 Contact Updates                              │
│    • Add William as Harvey's son                │
│                                                  │
│ 📝 Summary Note                                 │
│    👶 William was born (Sept 17, 2023)         │
│    🎉 Received raise at work                    │
│    💼 Interest in Life Insurance ($50,000) for │
│        William                                  │
│    💼 Interest in IUL contribution increase    │
│                                                  │
│ ✉️ Send Congratulations                        │
│    📱 Text: "Hi Harvey! Congratulations on     │
│        William's birth! 🎉👶..."               │
│    📱 Text: "Congratulations on your raise!"   │
│                                                  │
│ [Apply All] [Apply & Edit] [Skip for Now]      │
└─────────────────────────────────────────────────┘
```

## Benefits of This Approach

### ✅ Avoids SwiftData Fault Issues
- No more `@Model` objects being accessed outside their context
- Everything is created fresh and properly initialized
- Real data flow through the pipeline

### ✅ Tests Real Integration
- Contacts.app → SamPerson
- Products → Portfolio tracking
- Notes → LLM → Evidence → Insights
- Complete end-to-end flow

### ✅ Demonstrates Value
- Shows how SAM analyzes natural language notes
- Generates actionable suggestions
- Connects to real contacts
- Updates contact records automatically

### ✅ Easy to Extend
Add more scenarios by:
```swift
// Add another note
createAnotherNote(for: harvey, context: context)

// Add another product
createTermPolicy(for: harvey, context: context)

// Import another contact
importAnotherPerson(context: context)
```

## Setup Instructions

### 1. Add Harvey to Your Contacts
Open Contacts.app and create:
- **Name:** Harvey Snodgrass
- **Email:** harvey@example.com (optional)
- That's it!

### 2. Run the Fixture
In your development menu:
- Click "Restore Developer Fixture"
- Watch the console for progress logs

### 3. Observe the Pipeline
```
🌱 [FixtureSeeder] Starting fixture seed...
🗑️  [FixtureSeeder] Clearing all SwiftData...
✅ [FixtureSeeder] All data cleared
📇 [FixtureSeeder] Searching for Harvey Snodgrass...
✅ [FixtureSeeder] Harvey Snodgrass imported
💼 [FixtureSeeder] Creating IUL product...
✅ [FixtureSeeder] IUL created
📝 [FixtureSeeder] Creating note...
✅ [FixtureSeeder] Note created
🔍 [InsightGeneratorNotesAdapter] Starting analysis...
✅ [NoteLLMAnalyzer] LLM analysis complete
📝 [NoteEvidenceFactory] Created proposed link: Add William
✅ [FixtureSeeder] Fixture seed complete!
```

### 4. Check the Results
1. **People Tab** → See Harvey Snodgrass
2. **Inbox Tab** → See note evidence (needs review)
3. **Click the evidence** → See Smart Suggestion Card
4. **Click "Apply All"** → William added to Harvey's contact!

## Updating the Fixture Call

The fixture method signature changed from sync to async:

```swift
// OLD:
FixtureSeeder.seedIfNeeded(using: container)

// NEW:
Task {
    await FixtureSeeder.seedIfNeeded(using: container)
}
```

This needs to be updated wherever the fixture is called (likely in DevelopmentTab or similar).

## Testing Checklist

After running the fixture:

- [ ] Harvey appears in People list
- [ ] Harvey's IUL shows in products (when implemented)
- [ ] Note appears in Inbox as "Needs Review"
- [ ] Opening note shows LLM analysis
- [ ] Smart Suggestion Card displays with:
  - [ ] William as suggested dependent
  - [ ] Summary note content
  - [ ] Congratulations messages
- [ ] Clicking "Apply All":
  - [ ] Adds William to Harvey's contact in Contacts.app
  - [ ] Logs summary note (or writes if entitlement granted)
  - [ ] Shows success message
- [ ] Clicking "Apply & Edit" opens Contacts.app

## Future Enhancements

### Phase 2: Calendar Integration
```swift
// Import Harvey's calendar events
importCalendarEvents(for: harvey, context: context)
```

### Phase 3: Multiple Clients
```swift
// Import entire contact group
importClientsFromGroup("SAM Clients", context: context)
```

### Phase 4: Historical Notes
```swift
// Create a series of notes over time
createHistoricalNotes(for: harvey, context: context)
```

## Troubleshooting

**Harvey not found?**
- Make sure he exists in Contacts.app
- Grant Contacts permission to SAM
- Check spelling matches exactly

**No evidence created?**
- Check that InsightGenerator is running
- Look for LLM analysis logs
- Verify note was saved to SwiftData

**Suggestions not showing?**
- Check that NoteEvidenceFactory generates ProposedLinks
- Verify SmartSuggestionCard is in the view hierarchy
- Check console for analysis completion

**Can't add William?**
- Verify Contacts permission
- Check that Harvey has valid contactIdentifier
- Look for ContactSyncService error logs
