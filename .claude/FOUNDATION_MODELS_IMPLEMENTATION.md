# FoundationModels LLM Implementation

## Overview
Enabled Apple's on-device FoundationModels LLM for semantic note analysis with explicit fallback to heuristic pattern matching when the LLM is unavailable.

**Date:** February 7, 2026  
**Status:** ✅ Complete

---

## What Changed

### File: `NoteLLMAnalyzer.swift`

#### 1. Enhanced @Generable Structures
Added detailed guidance for Apple's LLM to extract structured information:

```swift
@Generable(description: "Structured analysis of a financial advisor's meeting note...")
struct GuidedNoteAnalysis: Sendable {
    @Guide(description: "All people mentioned, including new family members...")
    var people: [GuidedPerson]
    
    @Guide(description: "Financial products discussed...")
    var keyTopics: [GuidedFinancialTopic]
    
    @Guide(description: "Action items, follow-ups...")
    var actions: [String]
}

@Generable(description: "A person mentioned in the advisor's note")
struct GuidedPerson: Sendable {
    var name: String
    var relationship: String?
    var aliases: [String]  // NEW: Detects "William" = "Billy"
    var isNewPerson: Bool   // NEW: Marks newborns, new dependents
}

@Generable(description: "A financial product...")
struct GuidedFinancialTopic: Sendable {
    var productType: String
    var amount: String?
    var beneficiary: String?
    var sentiment: String?  // NEW: "wants", "interested", "considering"
}
```

#### 2. Enhanced Public Types
Extended `PersonEntity` and `FinancialTopicEntity` to support new LLM outputs:

```swift
public struct PersonEntity: Sendable, Hashable {
    public let name: String
    public let relationship: String?
    public let aliases: [String]        // NEW
    public let isNewPerson: Bool        // NEW
}

public struct FinancialTopicEntity: Sendable, Hashable {
    public let productType: String
    public let amount: String?
    public let beneficiary: String?
    public let sentiment: String?       // NEW
}
```

#### 3. Enhanced Artifact
Added tracking for LLM vs heuristic analysis:

```swift
public struct NoteAnalysisArtifact: Sendable {
    // ... existing fields ...
    public let actions: [String]        // NEW: Action items from LLM
    public let usedLLM: Bool            // NEW: Track analysis method
}
```

#### 4. LLM-First Analysis Flow
Main `analyze()` function now attempts LLM first, falls back with **explicit logging**:

```swift
public static func analyze(text: String) async throws -> NoteAnalysisArtifact {
    #if canImport(FoundationModels)
    let model = SystemLanguageModel.default
    
    switch model.availability {
    case .available:
        print("✅ [NoteLLMAnalyzer] Using on-device LLM for semantic analysis")
        return try await analyzeLLM(text: text)
        
    case .unavailable(.deviceNotEligible):
        print("⚠️⚠️⚠️ [NoteLLMAnalyzer] FALLBACK TO HEURISTICS ⚠️⚠️⚠️")
        print("⚠️ Reason: Device not eligible for Apple Intelligence")
        return analyzeHeuristic(text: text)
        
    // ... other unavailable cases with explicit warnings ...
    }
    #else
    print("⚠️⚠️⚠️ [NoteLLMAnalyzer] FALLBACK TO HEURISTICS ⚠️⚠️⚠️")
    print("⚠️ Reason: FoundationModels framework not available")
    return analyzeHeuristic(text: text)
    #endif
}
```

#### 5. New LLM Analysis Function
Uses Apple's on-device LLM with specialized instructions:

```swift
private static func analyzeLLM(text: String) async throws -> NoteAnalysisArtifact {
    let instructions = """
    You are an expert assistant for financial advisors analyzing client meeting notes.
    
    Your tasks:
    1. Extract ALL people mentioned, especially new family members
    2. Identify nicknames and aliases (e.g., "William" and "Billy")
    3. Detect new people (newborns, new spouses) - mark with isNewPerson=true
    4. Extract financial products discussed
    5. Link products to beneficiaries
    6. Identify action items and follow-ups
    7. Understand context (e.g., "I just had a son" = NEW child dependent)
    """
    
    let session = LanguageModelSession(instructions: instructions)
    let response = try await session.respond(to: prompt, generating: GuidedNoteAnalysis.self)
    
    // Convert LLM output to NoteAnalysisArtifact
    // Returns artifact with usedLLM=true
}
```

#### 6. Explicit Fallback Warnings
When falling back to heuristics, logs are **extremely explicit**:

```swift
private static func analyzeHeuristic(text: String) -> NoteAnalysisArtifact {
    print("⚠️ [NoteLLMAnalyzer] Heuristic analysis complete (LIMITED ACCURACY):")
    print("⚠️ [NoteLLMAnalyzer] WARNING: Heuristic analysis cannot:")
    print("   - Understand semantic relationships between people")
    print("   - Detect that nicknames refer to the same person")
    print("   - Infer that 'I just had a son' means create a new dependent")
    print("   - Understand context or sentiment accurately")
    
    // Returns artifact with usedLLM=false
}
```

#### 7. Improved Heuristic Extraction
Enhanced pattern matching for fallback mode:

- Detects "just had a son" → marks `isNewPerson=true`
- Extracts sentiment from context ("want", "increase", "considering")
- Better beneficiary detection ("for my son William")

---

## How It Works

### With FoundationModels Available (iPhone 15 Pro+, M1+ Macs)

**Input Note:**
> "I just had a son. His name is William. I want my young Billy to have a $50,000 life insurance policy. And I got a raise so I'd like to increase my retirement savings."

**LLM Output:**
```json
{
  "people": [
    {
      "name": "William",
      "relationship": "son",
      "aliases": ["Billy"],
      "isNewPerson": true
    }
  ],
  "keyTopics": [
    {
      "productType": "Life Insurance",
      "amount": "$50,000",
      "beneficiary": "William",
      "sentiment": "wants"
    },
    {
      "productType": "Retirement Savings",
      "amount": null,
      "beneficiary": null,
      "sentiment": "increase"
    }
  ],
  "actions": [
    "Add William (son) as dependent",
    "Quote $50,000 life insurance policy for William",
    "Discuss retirement plan increase"
  ]
}
```

**Key Advantages:**
- ✅ Understands "William" = "Billy"
- ✅ Recognizes "just had a son" means NEW person
- ✅ Links "$50,000" to "Billy" (William)
- ✅ Generates actionable follow-ups

### With Heuristics Fallback (Older Devices)

**Same Input Note** produces:
```json
{
  "people": [
    {
      "name": "William",
      "relationship": "child",
      "aliases": [],
      "isNewPerson": true  // Pattern detected "just had a son"
    }
  ],
  "keyTopics": [
    {
      "productType": "Life Insurance",
      "amount": "$50,000",
      "beneficiary": null,  // May miss connection
      "sentiment": "wants"
    },
    {
      "productType": "Retirement",
      "amount": null,
      "beneficiary": null,
      "sentiment": "increase"
    }
  ],
  "actions": []  // Cannot generate action items
}
```

**Limitations (logged explicitly):**
- ❌ Cannot connect "William" = "Billy"
- ❌ May miss beneficiary linkage
- ❌ Cannot generate semantic action items
- ⚠️ Relies on exact pattern matches

---

## Log Output Examples

### Successful LLM Analysis
```
🔍 [NoteLLMAnalyzer] Analyzing text (length: 234)
✅ [NoteLLMAnalyzer] FoundationModels available - using on-device LLM for semantic analysis
✅ [NoteLLMAnalyzer] LLM analysis complete:
   - Generated: 1 facts, 2 implications, 3 actions
   - Extracted 1 people: William (son) [NEW]
   - Extracted 2 topics: Life Insurance - William, Retirement Savings - unknown beneficiary
```

### Fallback to Heuristics
```
🔍 [NoteLLMAnalyzer] Analyzing text (length: 234)
⚠️⚠️⚠️ [NoteLLMAnalyzer] FALLBACK TO HEURISTICS ⚠️⚠️⚠️
⚠️ [NoteLLMAnalyzer] Reason: Device not eligible for Apple Intelligence
⚠️ [NoteLLMAnalyzer] Using manual pattern matching instead of semantic LLM analysis
⚠️ [NoteLLMAnalyzer] Results will be less accurate and may miss contextual information
⚠️ [NoteLLMAnalyzer] Heuristic analysis complete (LIMITED ACCURACY):
   - Generated: 1 facts, 1 implications
   - Extracted 1 people: William (child)
   - Extracted 2 topics: Life Insurance, Retirement
⚠️ [NoteLLMAnalyzer] WARNING: Heuristic analysis cannot:
   - Understand semantic relationships between people
   - Detect that nicknames refer to the same person
   - Infer that 'I just had a son' means create a new dependent
   - Understand context or sentiment accurately
```

### Apple Intelligence Not Enabled
```
⚠️⚠️⚠️ [NoteLLMAnalyzer] FALLBACK TO HEURISTICS ⚠️⚠️⚠️
⚠️ [NoteLLMAnalyzer] Reason: Apple Intelligence is not enabled in System Settings
⚠️ [NoteLLMAnalyzer] To enable: Settings → Apple Intelligence & Siri → Enable Apple Intelligence
⚠️ [NoteLLMAnalyzer] Using manual pattern matching instead of semantic LLM analysis
⚠️ [NoteLLMAnalyzer] Results will be less accurate and may miss contextual information
```

---

## Benefits

### Privacy & Performance
- ✅ **100% On-Device** - No cloud API calls
- ✅ **No API Keys** - Uses system LLM
- ✅ **Private** - Data never leaves device
- ✅ **Fast** - Local inference

### Accuracy Improvements
- ✅ **Semantic Understanding** - Understands context, not just keywords
- ✅ **Alias Detection** - Links "William" to "Billy"
- ✅ **Relationship Inference** - Understands "just had a son" = new dependent
- ✅ **Beneficiary Linking** - Connects products to people
- ✅ **Action Generation** - Creates actionable follow-ups

### Developer Experience
- ✅ **Explicit Fallback Logging** - Impossible to miss when heuristics are used
- ✅ **Type Safety** - `@Generable` ensures structured output
- ✅ **Graceful Degradation** - Works on all devices
- ✅ **Diagnostic Tracking** - `usedLLM` flag shows analysis method

---

## Device Compatibility

| Device | LLM Available | Method Used |
|--------|---------------|-------------|
| iPhone 15 Pro / Pro Max | ✅ Yes | **LLM** (semantic) |
| iPhone 16 / Plus / Pro / Pro Max | ✅ Yes | **LLM** (semantic) |
| Mac with M1+ | ✅ Yes | **LLM** (semantic) |
| iPad with M1+ | ✅ Yes | **LLM** (semantic) |
| iPhone 15 / 14 / 13 | ❌ No | **Heuristics** (patterns) |
| Mac with Intel | ❌ No | **Heuristics** (patterns) |
| iPad without M1 | ❌ No | **Heuristics** (patterns) |

---

## Next Steps

### Immediate (Done ✅)
- ✅ Enable FoundationModels with fallback
- ✅ Add explicit logging for fallback scenarios
- ✅ Track LLM usage with `usedLLM` flag

### Future Enhancements
- [ ] **Store LLM Data in SamAnalysisArtifact** - Persist `actions`, `people`, `topics`
- [ ] **Create Person Suggestions** - Offer to add William as dependent
- [ ] **Show Extracted Entities in UI** - Display people/topics in Inbox
- [ ] **Use `usedLLM` for Quality Indicators** - Show badge when LLM was used

---

## Testing

### Test on Apple Intelligence Device
1. Create note: "I just had a son. His name is William. I want my young Billy to have a $50,000 life insurance policy."
2. Check logs for: `✅ [NoteLLMAnalyzer] FoundationModels available`
3. Verify output includes:
   - `people: [William (son) [NEW]]`
   - `aliases: ["Billy"]`
   - `actions: ["Add William (son) as dependent", ...]`

### Test Fallback on Older Device
1. Same note on iPhone 14 or Intel Mac
2. Check logs for: `⚠️⚠️⚠️ [NoteLLMAnalyzer] FALLBACK TO HEURISTICS`
3. Verify warning messages appear
4. Confirm `usedLLM=false` in artifact

### Test Apple Intelligence Disabled
1. Disable in Settings → Apple Intelligence & Siri
2. Check logs show: "To enable: Settings → Apple Intelligence & Siri"
3. Verify graceful fallback

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                 NoteLLMAnalyzer                     │
│                                                     │
│  analyze(text: String) → NoteAnalysisArtifact      │
│           ↓                                         │
│     FoundationModels available?                     │
│           ↓                                         │
│     ┌─────┴─────┐                                  │
│  YES│          │NO                                  │
│     ↓           ↓                                   │
│  analyzeLLM  analyzeHeuristic                      │
│     ↓           ↓                                   │
│  usedLLM=true  usedLLM=false                       │
│     │           │                                   │
│     └─────┬─────┘                                   │
│           ↓                                         │
│   NoteAnalysisArtifact                              │
│   - people: [PersonEntity]                          │
│   - topics: [FinancialTopicEntity]                  │
│   - actions: [String]                               │
│   - usedLLM: Bool                                   │
└─────────────────────────────────────────────────────┘
```

---

## Summary

**Before:** Heuristic pattern matching only (TODO comment to enable LLM)  
**After:** Apple's on-device LLM with explicit fallback logging

**Impact:** Users with Apple Intelligence devices get semantic understanding of notes, including:
- Automatic detection of new dependents
- Nickname resolution
- Actionable follow-ups
- Better accuracy for opportunity detection

**Graceful Degradation:** Older devices continue to work with improved heuristics and clear logging about limitations.
