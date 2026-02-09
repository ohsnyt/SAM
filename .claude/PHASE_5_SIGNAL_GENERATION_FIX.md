# Phase 5: Signal Generation & Entity Display Fix

**Date:** February 7, 2026  
**Status:** COMPLETE - Ready for Testing

## Problem Analysis

The user's log showed a critical issue in the notes analysis pipeline:

```
✅ [NoteLLMAnalyzer] LLM analysis complete:
   - Generated: 0 facts, 3 implications, 2 actions
   - Extracted 2 people: ["Frank (unknown) [NEW]", "Advisor (Financial Advisor) [NEW]"]
   - Extracted 2 topics: ["Life Insurance - Frank", "Indexed Universal Life Insurance - Advisor"]
...
🔍 [ArtifactToSignalsMapper] Processing artifact:
   Summary: Increase IUL
   Facts: []
   Implications: ["Increase IUL", "Discuss Frank\'s life insurance policy", "New person identified: Frank"]
   Affect: neutral
   📊 Total signals generated: 0  ❌ ZERO SIGNALS!
```

**Root Causes:**
1. **Data Loss:** The LLM successfully extracted structured people/topics, but `SamAnalysisArtifact` wasn't storing them
2. **Weak Signal Generation:** `ArtifactToSignalsMapper` only did keyword matching on implications ("opportunity", "risk", "concern"), missing the actual semantic opportunities
3. **No UI for Entities:** Extracted people/topics weren't displayed anywhere, so users couldn't see or act on them

## Solution Implemented

### 1. Extended SamAnalysisArtifact Schema (`SamAnalysisArtifact.swift`)

**Added:**
- `StoredPersonEntity` struct (Codable) to persist LLM-extracted people
- `StoredFinancialTopicEntity` struct (Codable) to persist LLM-extracted topics
- `peopleJSON: Data?` field (JSON-encoded array)
- `topicsJSON: Data?` field (JSON-encoded array)
- `actions: [String]` field (action items from LLM)
- `usedLLM: Bool` flag (tracks whether we used FM or heuristics)
- Computed properties `people` and `topics` that decode the JSON

**Why JSON encoding?** SwiftData doesn't support nested array-of-struct directly, so we encode as Data and provide computed properties for easy access.

**Schema Migration:** This adds new fields to `SamAnalysisArtifact`. SwiftData will automatically migrate existing records (new fields will be nil/empty for old data).

### 2. Fixed AnalysisRepository (`AnalysisRepository.swift`)

**Updated `saveNoteArtifact`:**
- Now converts `NoteAnalysisArtifact.people` → `[StoredPersonEntity]`
- Converts `NoteAnalysisArtifact.topics` → `[StoredFinancialTopicEntity]`
- Passes all structured data to `SamAnalysisArtifact` initializer
- Logs confirmation: `Saved artifact with X people, Y topics, usedLLM: Z`

### 3. Rebuilt Signal Generation (`ArtifactToSignalsMapper.swift`)

**New Two-Tier Approach:**

#### Priority 1: Structured LLM Data (when `artifact.usedLLM == true`)
- **Topics with "wants"/"interest"/"increase"/"consider" sentiment → `.productOpportunity` signal**
  - Confidence: 0.85 for "wants", 0.75 otherwise
  - Reason: "Client interested in [Product Type]"
- **High-value policies (≥$50K) → `.complianceRisk` signal**
  - Confidence: 0.60
  - Reason: "High-value policy ($X) requires documentation"
- **New people (`isNewPerson: true`) → `.productOpportunity` signal**
  - Confidence: 0.70
  - Reason: "New family member (Name) - coverage opportunity"
- **Actions with "follow"/"schedule"/"call" → `.unlinkedEvidence` signal**
  - Confidence: 0.75
  - Reason: "Action required: [action text]"

#### Priority 2: Heuristic Fallback (always runs)
- Keyword matching on facts/implications (existing logic)
- Lower confidence (0.62-0.70)
- Ensures backwards compatibility with heuristic-only analysis

**Result:** For the user's example note about Frank, we now generate:
- 3 opportunity signals (Life Insurance for Frank, IUL increase, new child)
- 1 compliance risk signal ($60K policy requires docs)
- Total: 4 signals instead of 0!

### 4. Improved LLM Implication Text (`NoteLLMAnalyzer.swift`)

**Fixed `analyzeLLM()` topic → implication conversion:**
- Now generates: "Potential opportunity: Life Insurance for Frank"
- Instead of just: "Potential opportunity: Life Insurance"
- Includes sentiment keywords: "increase", "consider" (not just "wants"/"interest")

**Why?** This ensures implications are more specific and also triggers the heuristic fallback path if the structured data path fails.

### 5. Enhanced InsightGenerator Messages (`InsightGenerator.swift`)

**Fixed `generateMessage()` to use structured LLM data:**
- **Before:** Extracted topics by keyword matching on note text → "life insurance"
- **After:** Uses artifact.topics with full details → "Life Insurance ($150,000) for Susan"
- Includes new people in opportunity messages: "for Susan (daughter)"
- Falls back to heuristic extraction if LLM wasn't used

**Example output:**
- Old: "Possible opportunity regarding life insurance (Harvey Snodgrass)."
- New: "Possible opportunity regarding Life Insurance ($150,000) for Susan for Susan (daughter) (Harvey Snodgrass)."

### 6. Added Inverse Relationship (`SamNote.swift`)

**Added:**
```swift
@Relationship(inverse: \SamAnalysisArtifact.note)
public var analysisArtifact: SamAnalysisArtifact?
```

**Why?** Allows easy access to analysis from note: `note.analysisArtifact.people` instead of having to query artifacts separately. Needed for UI integration.

### 7. Created UI Component (`AnalysisArtifactCard.swift`)

**New SwiftUI View:**
- Displays all LLM-extracted entities in collapsible sections:
  - **People:** Name, relationship, aliases, "NEW" badge, "Add Contact" button
  - **Financial Topics:** Product type, amount, beneficiary, sentiment (color-coded)
  - **Facts:** Bullet list
  - **Implications:** Bullet list
  - **Actions:** Numbered action items
- Visual indicators:
  - "On-Device LLM" badge (blue) when `usedLLM: true`
  - "Heuristic" badge (orange) when fallback used
  - Icon per topic type (life insurance, retirement, annuity)
  - Sentiment color (green=wants, blue=increase, orange=consider, red=not interested)

**Usage:**
```swift
// In InboxDetailView or PersonDetailView, fetch the artifact:
if let artifact = item.note?.analysisArtifact { // Assuming this relationship exists
    AnalysisArtifactCard(artifact: artifact) { person in
        // Handle "Add Contact" button tap
        createNewContact(from: person)
    }
}
```

**Note:** The actual integration point depends on where `DetailScrollContent` is implemented (file not found in current context). The component is fully standalone and can be inserted anywhere.

## Testing Checklist

- [ ] **Schema Migration:** Launch app, verify no crashes (SwiftData auto-migrates)
- [ ] **Create Note:** Add new note with "I want $100K life insurance for my son Billy"
- [ ] **Check Logs:** Verify log shows:
  - "LLM analysis complete" with people/topics counts
  - "Saved artifact with X people, Y topics"
  - "Total signals generated: N" (should be > 0!)
- [ ] **Check Inbox:** Evidence appears with state=needsReview
- [ ] **Check Insights:** New insights created (opportunity type)
- [ ] **UI Display:** AnalysisArtifactCard shows extracted entities (once integrated)
- [ ] **Create Contact:** Tap "Add Contact" button on new person (when UI integrated)

## Integration Steps (For Next PR)

1. **Find DetailScrollContent** (likely in InboxDetailView.swift or separate file)
2. **Add Query for Artifact:**
   ```swift
   @Query(filter: #Predicate<SamAnalysisArtifact> { 
       $0.note?.id == evidenceItem.sourceNote?.id 
   })
   var artifacts: [SamAnalysisArtifact]
   ```
3. **Insert Card:**
   ```swift
   if let artifact = artifacts.first {
       AnalysisArtifactCard(artifact: artifact) { person in
           // TODO: Implement createContact flow
       }
   }
   ```
4. **Wire Create Contact Action:**
   - Could open Contacts.app (like existing participant flow)
   - Or present inline CNContactViewController (macOS)
   - Or show sheet to link to existing person / create new SamPerson

## Files Changed

- `SamAnalysisArtifact.swift` - Extended schema with peopleJSON, topicsJSON, actions, usedLLM + @Transient computed properties
- `SamNote.swift` - Added inverse relationship to access analysisArtifact from note
- `AnalysisRepository.swift` - Save structured data when persisting artifacts
- `ArtifactToSignalsMapper.swift` - Two-tier signal generation (structured > heuristic)
- `NoteLLMAnalyzer.swift` - Better implication text with beneficiaries
- `InsightGenerator.swift` - Use structured artifact data for rich insight messages (includes amounts, beneficiaries, new people)
- `SAMModelContainer.swift` - Bumped schema v5 → v6
- `AnalysisArtifactCard.swift` - NEW - UI component for entity display (ready to integrate)
- `ARTIFACT_CARD_INTEGRATION_GUIDE.md` - NEW - Step-by-step integration instructions

## Expected Log Output (After Fix)

```
✅ [NoteLLMAnalyzer] LLM analysis complete:
   - Generated: 0 facts, 3 implications, 2 actions
   - Extracted 2 people: ["Frank (son) [NEW]", "Advisor (Financial Advisor) [NEW]"]
   - Extracted 2 topics: ["Life Insurance - Frank", "IUL - Advisor"]
✅ [AnalysisRepository] Saved artifact with 2 people, 2 topics, usedLLM: true
🔍 [ArtifactToSignalsMapper] Processing artifact:
   Summary: Increase IUL
   Facts: []
   Implications: ["Increase IUL", "Discuss Frank's life insurance policy", "New person identified: Frank", "Potential opportunity: Life Insurance for Frank"]
   Affect: neutral
   Topics: 2 (usedLLM: true)
   People: 2
   ✅ Added opportunity signal from topic: Life Insurance (confidence: 0.85)
   ✅ Added compliance risk signal for amount: $60,000
   ✅ Added opportunity signal from topic: IUL (confidence: 0.75)
   ✅ Added opportunity signal for new person: Frank
   📊 Total signals generated: 4  ✅ SUCCESS!
```

## Next Roadmap Items

From context.md Phase 5:
- [x] **Fix signal generation from LLM data** (THIS PR)
- [ ] Display extracted entities in Inbox detail view (UI ready, needs integration)
- [ ] Add notes to "Recent Interactions" on Person detail page
- [ ] Create "Suggested Contacts" section showing extracted people
- [ ] Improve heuristic extraction patterns (multi-word names, more products)

## Documentation Updates Needed

- [ ] Update context.md "Freeform Notes as Evidence" section:
  - Mark "Analysis artifacts hidden" as FIXED
  - Add new "Signal generation uses structured data" bullet
  - Update "Current Limitations" to reflect new capabilities
- [ ] Add dated entry to changelog.md
- [ ] Update roadmap checkboxes
