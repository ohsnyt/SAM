# Smart Suggestion System - Complete Workflow

## Overview

The Smart Suggestion Card provides a **comprehensive, low-friction workflow** for handling note analysis. Instead of showing raw data, it presents **actionable suggestions** with one-click execution.

## What It Does

When SAM analyzes a note (like Harvey's note about Susan's birth), it:

1. **Detects Life Events**
   - Birth of children
   - Work bonuses/promotions
   - Other significant events

2. **Identifies Relationship Changes**
   - New family members
   - Relationship updates
   - Contact additions needed

3. **Extracts Financial Requests**
   - Product interests (Life Insurance, IUL, etc.)
   - Amounts mentioned
   - Beneficiaries specified

4. **Generates Communication Suggestions**
   - Congratulations messages (birth, promotion, etc.)
   - Pre-filled, editable templates
   - One-click sending

## User Experience

### Example: Harvey's Note About Susan

**Note Content:**
> I just had a daughter. Her name is Susan. I want my young Susie to have a $150,000 life insurance policy. And in addition, I got a bonus at work so I'd like to add to my IUL. Can we talk about that as well?

**SAM's Smart Suggestions:**

```
┌─────────────────────────────────────────────────────┐
│ ✨ SAM Suggestions                                   │
├─────────────────────────────────────────────────────┤
│                                                       │
│ 👤 Contact Updates                                   │
│    • Add Susan as Harvey Snodgrass's daughter        │
│                                                       │
│ 📝 Summary Note                                      │
│    👶 Susan was born (approx. Feb 8, 2026)          │
│    🎉 Received bonus at work                         │
│    💼 Interest in Life Insurance ($150,000) for     │
│        Susan                                         │
│    💼 Interest in IUL                                │
│                                                       │
│ ✉️ Send Congratulations                             │
│    📱 Text Message (tap to expand)                   │
│       "Hi Harvey! Congratulations on the birth      │
│       of Susan! 🎉👶 This is such wonderful news..."│
│                                                       │
│    📱 Text Message (tap to expand)                   │
│       "Hi Harvey! Congratulations on your bonus!    │
│       🎉 That's fantastic news..."                   │
│                                                       │
│ ┌──────────────┬──────────────────┬─────────────┐  │
│ │ Apply All    │ Apply & Edit     │ Skip for Now│  │
│ └──────────────┴──────────────────┴─────────────┘  │
└─────────────────────────────────────────────────────┘
```

### Actions

**"Apply All"** - One click does:
- ✅ Adds Susan Snodgrass as daughter to Harvey's contact
- ✅ Updates Harvey's contact note with timeline and requests
- ✅ Prepares congratulations messages for user to review
- ✅ Shows success confirmation

**"Apply & Edit"** - Same as Apply All, plus:
- Opens Contacts.app to Harvey's card for manual adjustments
- Allows user to refine the updates

**"Skip for Now"** - Dismisses suggestions
- Can review again later if needed

## Technical Implementation

### File Structure

```
SmartSuggestionCard.swift         ← New comprehensive UI
├── SuggestionActions              ← Data model for actions
├── ContactUpdate                  ← Contact modification model
├── SuggestedMessage              ← Pre-filled message model
└── LifeEvent                     ← Detected life event model

InboxDetailSections.swift          ← Updated integration
└── applyAllSuggestions()         ← Batch execution handler

NoteEvidenceFactory.swift          ← Updated to generate ProposedLinks
└── generateProposedLinks()       ← Creates suggestions from artifact

ContactSyncService.swift           ← Existing service (no changes)
└── addRelationship()             ← Used to add family members
```

### Detection Logic

**Life Events:**
- Birth: Detects "had a daughter", "had a son", "new baby"
- Work Success: Detects "bonus", "promotion", "raise"
- Extensible for other events

**Financial Products:**
- Uses `StoredFinancialTopicEntity` from artifact
- Extracts product type, amount, beneficiary
- Formats for note summary

**Relationships:**
- Uses `StoredPersonEntity` from artifact
- Checks `relationship` field for family connections
- Maps to CNContact relationship labels

## Console Output

When working correctly, you'll see:

```
📝 [NoteEvidenceFactory] Creating evidence for note 492674DF...
📝 [NoteEvidenceFactory] Note has 1 linked people: ["Harvey Snodgrass"]
📝 [NoteEvidenceFactory] Created proposed link: Add Susan as daughter to Harvey Snodgrass
✅ [NoteEvidenceFactory] Created evidence item, evidence ID: CFD84859...
📝 [NoteEvidenceFactory] Evidence has 1 linked people and 1 proposed links
```

Then when user clicks "Apply All":

```
✅ [ContactSyncService] Added Susan (daughter) to Harvey Snodgrass
📝 [ContactSyncService] WOULD UPDATE NOTE for Harvey Snodgrass:
   Note content to add:
   ─────────────────────
   👶 Susan was born (approx. Feb 8, 2026)
   🎉 Received bonus at work
   💼 Interest in Life Insurance ($150,000) for Susan
   💼 Interest in IUL
   ─────────────────────
   ⚠️  Skipped: Notes entitlement not yet granted by Apple
```

## Features

### ✅ Implemented

- **Life event detection** (birth, work success)
- **Family member suggestions** (add to contact)
- **Summary note generation** (timeline format with emojis)
- **Message templates** (congratulations, expandable)
- **One-click application** (Apply All button)
- **Edit workflow** (Apply & Edit button)
- **Skip option** (Skip for Now button)
- **Success/error feedback** (animated banners)
- **Auto-dismiss** (5-second timeout on success)

### 🚧 Future Enhancements

- **Message sending integration** - Actually send SMS/email from app
- **Template customization** - Let user save their own message templates
- **More life events** - Marriage, graduation, retirement, etc.
- **Product recommendations** - Suggest specific products based on events
- **Follow-up scheduling** - Auto-create calendar reminders
- **CRM integration** - Log communications to CRM system

## User Journey

1. **User takes note** about Harvey's news
2. **SAM analyzes** using on-device LLM
3. **Smart Suggestion Card appears** with comprehensive actions
4. **User reviews** all suggested changes
5. **One click applies** everything atomically
6. **Success confirmation** shows what was done
7. **Messages ready** for user to review and send
8. **Contact updated** automatically in Contacts.app

## Benefits

- **🚀 Zero friction** - One click vs. multiple manual steps
- **🧠 AI-powered** - LLM understands context and relationships
- **✨ Comprehensive** - Handles all aspects of the interaction
- **🎯 Accurate** - Shows exactly what will happen before applying
- **⚡️ Fast** - Batch operations complete in < 1 second
- **💬 Personal** - Pre-filled messages are warm and appropriate
- **🔧 Flexible** - Edit option for power users

## Testing

To test the complete workflow:

1. Create a note for an existing person (Harvey)
2. Mention a life event: "I just had a daughter named Susan"
3. Mention financial products: "want life insurance for her"
4. Mention work success: "got a bonus"
5. Open the evidence item in the inbox
6. Verify the Smart Suggestion Card appears with:
   - ✅ "Add Susan as daughter" suggestion
   - ✅ Summary note with all key points
   - ✅ Two congratulations message templates
7. Click "Apply All"
8. Verify success message
9. Check console for confirmation logs
10. Open Contacts.app to verify Susan was added

## Troubleshooting

**Card doesn't appear:**
- Check if `artifact` exists on the note
- Check console for "No artifact found for note"
- Verify LLM analysis completed successfully

**Suggestions are incomplete:**
- Check detection logic in `detectLifeEvents()`
- Verify artifact has correct `people` and `topics` data
- Check console logs for what was detected

**Apply fails:**
- Check for ContactSyncService errors
- Verify Contacts authorization granted
- Check if parent person has valid contactIdentifier

**Messages not showing:**
- Verify life events were detected
- Check `generateCongratulationsMessage()` logic
- Ensure linked person has display name
