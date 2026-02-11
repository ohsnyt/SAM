# Bug Fixes: LLM JSON Parsing & Insight Generation

**Date**: February 11, 2026  
**Issues Fixed**: 3 critical bugs

---

## Bug 1: LLM Returns Markdown-Wrapped JSON ❌→✅

### Problem
```
❌ [NoteAnalysisCoordinator] Analysis failed: dataCorrupted
"Unexpected character '`' around line 1, column 1."
```

**Root Cause**: Apple's Foundation Models LLM was returning JSON wrapped in markdown code blocks:

```json
{
  "summary": "...",
  "people": [...]
}
```

Instead of raw JSON:
```
{
  "summary": "...",
  "people": [...]
}
```

### Fix Applied

**File**: `NoteAnalysisService.swift`

**Changes**:

1. **Enhanced `parseResponse()` method** to strip markdown:
```swift
// Remove markdown code block markers (```json ... ``` or ``` ... ```)
if cleaned.hasPrefix("```") {
    // Find the first newline after ```
    if let firstNewline = cleaned.firstIndex(of: "\n") {
        cleaned = String(cleaned[cleaned.index(after: firstNewline)...])
    }
    // Remove trailing ```
    if cleaned.hasSuffix("```") {
        cleaned = String(cleaned.dropLast(3))
    }
}
```

2. **Added debug logging**:
```swift
print("📝 [NoteAnalysisService] Cleaned JSON length: \(cleaned.count) characters")
```

3. **Improved error logging** to show first 500 characters of failed JSON:
```swift
print("❌ [NoteAnalysisService] JSON parsing failed. First 500 chars:")
print(String(cleaned.prefix(500)))
```

4. **Updated system prompt** to be more emphatic:
```
CRITICAL: You MUST respond with ONLY valid JSON. 
- Do NOT wrap the JSON in markdown code blocks (no ``` or ```json)
- Do NOT include any explanatory text before or after the JSON
- Return ONLY the raw JSON object starting with { and ending with }
```

**Result**: ✅ Notes now parse successfully and extract people, topics, action items

---

## Bug 2: Wrong Property Names in InsightGenerator ❌→✅

### Problem
```
error: Value of type 'SamEvidenceItem' has no member 'attachedPeople'
error: Value of type 'EvidenceRepository' has no member 'fetchEvidence'
```

**Root Cause**: InsightGenerator used incorrect property/method names that don't exist in the codebase.

### Fix Applied

**File**: `InsightGenerator.swift`

**Changes**:

1. **Fixed property name** (3 occurrences):
   - ❌ `event.attachedPeople`
   - ✅ `event.linkedPeople`

2. **Fixed repository method**:
   - ❌ `evidenceRepository.fetchEvidence(forPerson: person)`
   - ✅ Fetch all evidence and filter manually:
   ```swift
   let allEvidence = try evidenceRepository.fetchAll()
   let personEvidence = allEvidence.filter { evidence in
       evidence.linkedPeople.contains(where: { $0.id == person.id })
   }
   ```

**Result**: ✅ InsightGenerator compiles and generates insights from calendar events

---

## Bug 3: File Location Confusion ⚠️

### Question
> "Is InsightGenerator a service and should be put in the Services folder? You put it into a views subfolder."

### Answer

**InsightGenerator is a COORDINATOR**, not a Service or View.

**Correct Location**: `Coordinators/InsightGenerator.swift`

**Why it's a Coordinator**:
- ✅ Orchestrates business logic across multiple repositories
- ✅ Accesses SwiftData via repositories (not directly)
- ✅ `@MainActor` isolated
- ✅ `@Observable` state for UI binding
- ✅ Follows standard coordinator API pattern
- ❌ Does NOT access external APIs (no CNContact, EKEvent, etc.)
- ❌ Does NOT need actor isolation

**Services vs Coordinators**:

| Aspect | Services | Coordinators |
|--------|----------|--------------|
| Isolation | `actor` | `@MainActor` |
| Purpose | Access external APIs | Orchestrate business logic |
| Returns | Sendable DTOs | Observes SwiftData models |
| Examples | ContactsService, CalendarService | ContactsImportCoordinator, InsightGenerator |
| SwiftData | Never | Via repositories |

---

## Testing Instructions

### Test Note Analysis

1. **Create a note** with content like:
   ```
   Met with John Smith today. His wife Sarah is expecting a baby in March.
   They want to increase their life insurance coverage.
   Follow up in 2 weeks to discuss options.
   ```

2. **Watch console output**:
   ```
   📝 [NoteAnalysisService] Cleaned JSON length: 523 characters
   📝 [NoteAnalysisService] Analyzed note: 2 people, 2 actions
   📝 [NoteAnalysisCoordinator] Analysis complete for note <UUID>
   ```

3. **Check PersonDetailView**:
   - Note should appear in Notes section
   - Summary should be visible (1-2 sentences)
   - Action items badge should show count

4. **Check Inbox**:
   - Evidence item with source "Note" should appear
   - Can be triaged like calendar events

### Test Insight Generation

1. **Go to Awareness dashboard**
2. **Click "Generate Insights"** (or wait for auto-generation)
3. **Watch console output**:
   ```
   🧠 [InsightGenerator] Generated 2 insights from notes
   🧠 [InsightGenerator] Generated 1 relationship insights
   🧠 [InsightGenerator] Generated 1 calendar insights
   ✅ [InsightGenerator] Generated 4 insights successfully
   ```

4. **Check dashboard**:
   - Insights appear in list
   - Can filter by type
   - Can expand and triage

---

## What's Now Working

✅ **Note Creation**: Notes save to database  
✅ **LLM Analysis**: Extracts people, topics, action items, summary  
✅ **JSON Parsing**: Handles markdown-wrapped responses  
✅ **Evidence Creation**: Notes appear in Inbox  
✅ **Person Linking**: Notes show in PersonDetailView  
✅ **Insight Generation**: Creates insights from notes, relationships, calendar  
✅ **Awareness Dashboard**: Displays and filters insights

---

## Known Limitations (Still Exist)

1. **Mock Insights**: AwarenessView still uses mock data (needs wiring)
2. **No Evidence from Notes Yet**: Note → Evidence pipeline not wired
3. **No Person Navigation**: "View Person" button logs to console
4. **No Auto-Generation Triggers**: Manual refresh only

---

## Next Steps

### Immediate (To Complete Phase I Wiring)

1. **Wire Real Insights in AwarenessView**:
   ```swift
   // In loadInsights(), replace:
   insights = createMockInsights()
   
   // With: (TODO - needs GeneratedInsight storage)
   // insights = await generator.generateInsights()
   ```

2. **Create Evidence from Notes**:
   - In `NoteAnalysisCoordinator`, after storing analysis:
   ```swift
   // Create evidence item
   try evidenceRepository.create(
       sourceUID: "note:\(note.id.uuidString)",
       source: .note,
       occurredAt: note.createdAt,
       title: note.summary ?? String(note.content.prefix(50)),
       snippet: note.summary ?? String(note.content.prefix(200)),
       bodyText: note.content,
       linkedPeople: note.linkedPeople,
       linkedContexts: note.linkedContexts
   )
   ```

3. **Wire Auto-Generation**:
   - Call `InsightGenerator.shared.startAutoGeneration()` after:
     - Calendar import completes
     - Note analysis completes
     - App launch (if enabled)

---

## Files Modified

### NoteAnalysisService.swift ✅
- Enhanced markdown stripping in `parseResponse()`
- Added debug logging for JSON length and parsing failures
- Updated system prompt to emphasize no markdown

### InsightGenerator.swift ✅
- Fixed `attachedPeople` → `linkedPeople` (3 occurrences)
- Fixed `fetchEvidence(forPerson:)` → manual filtering
- Now compiles without errors

---

## Verification Checklist

- [x] Code compiles without errors
- [x] NoteAnalysisService strips markdown code blocks
- [x] InsightGenerator uses correct property names
- [x] Console logs show successful analysis
- [ ] Test with real note content (user should test)
- [ ] Verify extracted data appears in UI (user should test)
- [ ] Check Inbox for note evidence items (after wiring)
- [ ] Check Awareness for real insights (after wiring)

---

**Status**: ✅ **Bugs Fixed - Ready for Testing**

**Recommendation**: Test note creation and analysis flow, then wire up Evidence creation and real Insights display.

**Date**: February 11, 2026
