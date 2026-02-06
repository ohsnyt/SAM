# Phase 2: Mature Insight Generation Pipeline — Completion Plan

**Status:** In Progress (Basic scaffold exists)  
**Date:** February 5, 2026  
**Goal:** Complete the migration of Awareness from runtime `EvidenceBackedInsight` computation to persisted `SamInsight` queries.

---

## Current State

### ✅ What's Working
- `InsightGenerator` actor exists with basic generation logic
- `AwarenessHost` has a feature flag (`usePersistedInsights`) that toggles between old and new paths
- Persisted insights navigate to Person/Context when linked
- Dismiss functionality works
- Phase 1 foundation is complete (insights persist, backup/restore works)

### 🚧 What Needs Work

1. **Duplicate Prevention** — Current implementation only checks if evidence ID exists; needs composite uniqueness
2. **Automatic Generation** — No automatic triggers after imports (must be manually called)
3. **Message Quality** — Basic templates don't match the quality of the old bucketing system
4. **Signal Mapping** — `SignalKind → InsightKind` logic is overly simplistic
5. **Evidence Aggregation** — Each evidence item creates one insight; should aggregate related signals
6. **Migration Path** — Feature flag exists but default is still `true` (old path); need validation before flipping

---

## Task Breakdown

### Task 1: Improve Duplicate Prevention

**Current Problem:**
```swift
private func hasInsightReferencingEvidence(_ evidenceID: UUID) async -> Bool {
    // This only checks if evidence is referenced
    // Doesn't prevent duplicate insights for same person+kind+message
}
```

**Solution:** Add composite uniqueness check

**Files to change:**
- `InsightGenerator.swift`

**Implementation:**
```swift
// Inside InsightGenerator actor:

/// Check if an insight already exists for this entity+kind combination.
/// Prevents duplicates when same signal appears in multiple evidence items.
private func hasInsight(
    person: SamPerson?,
    context: SamContext?,
    kind: InsightKind
) async -> SamInsight? {
    let fetch = FetchDescriptor<SamInsight>(
        predicate: #Predicate<SamInsight> { insight in
            insight.dismissedAt == nil &&
            insight.kind == kind &&
            (person == nil || insight.samPerson?.id == person?.id) &&
            (context == nil || insight.samContext?.id == context?.id)
        }
    )
    return try? context.fetch(fetch).first
}

/// Update or create insight for given signal and evidence.
func generateInsights(for evidence: SamEvidenceItem) async {
    guard let best = evidence.signals.max(by: { $0.confidence < $1.confidence }) else { return }
    
    let person = evidence.linkedPeople.first
    let contextRef = evidence.linkedContexts.first
    let kind = insightKind(for: best.kind)
    
    // Check for existing insight
    if let existing = await hasInsight(person: person, context: contextRef, kind: kind) {
        // Update existing: add evidence ID if not already present, bump confidence if higher
        if !existing.evidenceIDs.contains(evidence.id) {
            existing.evidenceIDs.append(evidence.id)
            existing.interactionsCount += 1
            if best.confidence > existing.confidence {
                existing.confidence = best.confidence
            }
        }
    } else {
        // Create new
        let message = defaultMessage(for: best, person: person, context: contextRef)
        let insight = SamInsight(
            samPerson: person,
            samContext: contextRef,
            kind: kind,
            message: message,
            confidence: best.confidence,
            evidenceIDs: [evidence.id],
            interactionsCount: 1,
            consentsCount: 0
        )
        context.insert(insight)
    }
}

/// Map SignalKind → InsightKind using the same logic as AwarenessHost.bucketFor
private func insightKind(for signalKind: SignalKind) -> InsightKind {
    switch signalKind {
    case .complianceRisk:
        return .complianceWarning
    case .divorce:
        return .relationshipAtRisk
    case .comingOfAge, .unlinkedEvidence:
        return .followUp
    case .partnerLeft, .productOpportunity:
        return .opportunity
    }
}
```

**Testing:**
- [ ] Create 3 evidence items with same signal + same person → Should produce 1 insight with 3 evidence IDs
- [ ] Create evidence with divorce signal for Alice → dismiss insight → create new divorce evidence for Alice → Should NOT recreate dismissed insight
- [ ] Generate insights → delete evidence item → verify insight still exists but with fewer evidence IDs

---

### Task 2: Wire Automatic Generation After Imports

**Current Problem:** Generation must be manually triggered; not integrated with import pipeline.

**Solution:** Add debounced runner that kicks after Calendar/Contacts imports.

**Files to change:**
- `CalendarImportCoordinator.swift`
- `ContactsImportCoordinator.swift`
- **NEW:** `DebouncedInsightRunner.swift`

**Implementation:**

**Step 2.1: Create DebouncedInsightRunner**

```swift
//
//  DebouncedInsightRunner.swift
//  SAM_crm
//
//  Debounces insight generation requests to avoid running the generator
//  on every single evidence import. Coalesces bursts into a single run.
//

import Foundation
import SwiftData

/// Debounces insight generation to run once after a burst of evidence imports.
@MainActor
final class DebouncedInsightRunner: ObservableObject {
    private var task: Task<Void, Never>?
    private let container: ModelContainer
    private let debounceInterval: TimeInterval
    
    init(container: ModelContainer, debounceInterval: TimeInterval = 2.0) {
        self.container = container
        self.debounceInterval = debounceInterval
    }
    
    /// Request insight generation. Debounced: only runs after no new requests for `debounceInterval`.
    func kick(reason: String) {
        // Cancel pending task
        task?.cancel()
        
        // Schedule new task
        task = Task {
            do {
                try await Task.sleep(for: .seconds(debounceInterval))
                guard !Task.isCancelled else { return }
                
                DevLogger.log("🧠 [InsightRunner] Generating insights (reason: \(reason))")
                
                // Create background context for generation
                let context = ModelContext(container)
                let generator = InsightGenerator(context: context)
                await generator.generatePendingInsights()
                
                DevLogger.log("✅ [InsightRunner] Insight generation complete")
            } catch {
                DevLogger.log("❌ [InsightRunner] Generation failed: \(error)")
            }
        }
    }
}
```

**Step 2.2: Add DebouncedInsightRunner to App**

In `SAM_crmApp.swift`:

```swift
@main
struct SAM_crmApp: App {
    // ... existing code ...
    
    // Add insight runner
    @StateObject private var insightRunner: DebouncedInsightRunner
    
    init() {
        // ... existing init code ...
        
        // Initialize insight runner after container is created
        _insightRunner = StateObject(wrappedValue: DebouncedInsightRunner(container: sharedModelContainer))
    }
    
    var body: some Scene {
        WindowGroup {
            AppShellView()
                .modelContainer(sharedModelContainer)
                .environmentObject(insightRunner)  // Make available to coordinators
        }
        // ... settings window, etc ...
    }
}
```

**Step 2.3: Kick from CalendarImportCoordinator**

```swift
// In CalendarImportCoordinator, add:
@EnvironmentObject private var insightRunner: DebouncedInsightRunner

// After successful import:
private func performImport() async {
    // ... existing import logic ...
    
    // Kick insight generation after evidence is saved
    await MainActor.run {
        insightRunner.kick(reason: "calendar import")
    }
}
```

**Step 2.4: Kick from ContactsImportCoordinator**

```swift
// In ContactsImportCoordinator, similar pattern:
@EnvironmentObject private var insightRunner: DebouncedInsightRunner

private func performImport() async {
    // ... existing import logic ...
    
    await MainActor.run {
        insightRunner.kick(reason: "contacts import")
    }
}
```

**Testing:**
- [ ] Import 10 calendar events rapidly → verify generation runs once (debounced)
- [ ] Import contacts → verify insights appear within 3 seconds
- [ ] Check dev logs for insight generation timing

---

### Task 3: Improve Message Templates

**Current Problem:** Messages are generic and don't match the quality/context-awareness of the old bucketing system.

**Solution:** Port message generation logic from `AwarenessHost.SignalBucket.message(target:)`

**Files to change:**
- `InsightGenerator.swift`

**Implementation:**

```swift
// Replace defaultMessage(for:) with:

/// Generate a contextual message for this signal.
/// Matches the quality of the old AwarenessHost bucketing system.
private func defaultMessage(
    for signal: EvidenceSignal,
    person: SamPerson?,
    context: SamContext?
) -> String {
    // Build target suffix
    let targetSuffix: String
    if let ctx = context {
        targetSuffix = " (\(ctx.name))"
    } else if let p = person {
        targetSuffix = " (\(p.displayName))"
    } else {
        targetSuffix = ""
    }
    
    switch signal.kind {
    case .complianceRisk:
        return "Compliance review recommended\(targetSuffix)."
    case .divorce:
        return "Possible relationship change detected\(targetSuffix). Consider a check-in."
    case .comingOfAge:
        return "Coming of age event\(targetSuffix). Review dependent coverage."
    case .partnerLeft:
        return "Business change detected\(targetSuffix). Review buy-sell agreements."
    case .productOpportunity:
        return "Possible opportunity\(targetSuffix). Consider reviewing options."
    case .unlinkedEvidence:
        return "Suggested follow-up\(targetSuffix)."
    }
}
```

**Testing:**
- [ ] Generate insight for Alice (person) → message includes "(Alice Smith)"
- [ ] Generate insight for Smith Household (context) → message includes "(Smith Household)"
- [ ] Generate insight for unlinked evidence → message has no suffix

---

### Task 4: Add Evidence Aggregation

**Current Problem:** Each evidence item generates one insight. Related signals should aggregate into a single insight.

**Solution:** Make `generatePendingInsights()` work in two passes:
1. Group evidence by (person, context, kind)
2. Create one insight per group with all related evidence IDs

**Files to change:**
- `InsightGenerator.swift`

**Implementation:**

```swift
// Replace generatePendingInsights() with:

/// Generate insights by grouping related evidence items.
/// This creates one insight per (person, context, kind) tuple instead of
/// one insight per evidence item.
func generatePendingInsights() async {
    // Fetch all evidence with signals
    let fetch = FetchDescriptor<SamEvidenceItem>()
    let evidence: [SamEvidenceItem] = (try? context.fetch(fetch)) ?? []
    
    // Group by (person, context, signal kind)
    var groups: [InsightGroupKey: [SamEvidenceItem]] = [:]
    
    for item in evidence where !item.signals.isEmpty {
        guard let best = item.signals.max(by: { $0.confidence < $1.confidence }) else { continue }
        
        let key = InsightGroupKey(
            personID: item.linkedPeople.first?.id,
            contextID: item.linkedContexts.first?.id,
            signalKind: best.kind
        )
        
        groups[key, default: []].append(item)
    }
    
    // Generate one insight per group
    for (key, items) in groups {
        await generateOrUpdateInsight(for: items, key: key)
    }
    
    try? context.save()
}

private func generateOrUpdateInsight(for evidence: [SamEvidenceItem], key: InsightGroupKey) async {
    let kind = insightKind(for: key.signalKind)
    
    // Resolve person/context from IDs
    let person: SamPerson? = if let id = key.personID {
        try? context.fetch(FetchDescriptor<SamPerson>(predicate: #Predicate { $0.id == id })).first
    } else { nil }
    
    let contextRef: SamContext? = if let id = key.contextID {
        try? context.fetch(FetchDescriptor<SamContext>(predicate: #Predicate { $0.id == id })).first
    } else { nil }
    
    // Check for existing insight
    if let existing = await hasInsight(person: person, context: contextRef, kind: kind) {
        // Update: merge evidence IDs
        let newIDs = evidence.map(\.id).filter { !existing.evidenceIDs.contains($0) }
        existing.evidenceIDs.append(contentsOf: newIDs)
        existing.interactionsCount = existing.evidenceIDs.count
        
        // Update confidence to max across all evidence
        let maxConf = evidence
            .flatMap(\.signals)
            .map(\.confidence)
            .max() ?? existing.confidence
        if maxConf > existing.confidence {
            existing.confidence = maxConf
        }
    } else {
        // Create new insight
        let bestSignal = evidence
            .flatMap(\.signals)
            .max(by: { $0.confidence < $1.confidence })
        
        guard let signal = bestSignal else { return }
        
        let message = defaultMessage(for: signal, person: person, context: contextRef)
        let insight = SamInsight(
            samPerson: person,
            samContext: contextRef,
            kind: kind,
            message: message,
            confidence: signal.confidence,
            evidenceIDs: evidence.map(\.id),
            interactionsCount: evidence.count,
            consentsCount: 0
        )
        context.insert(insight)
    }
}

// Helper struct for grouping
private struct InsightGroupKey: Hashable {
    let personID: UUID?
    let contextID: UUID?
    let signalKind: SignalKind
}
```

**Testing:**
- [ ] Create 5 divorce signals for Alice → Should produce 1 insight with 5 evidence IDs
- [ ] Create 3 unlinked signals + 2 compliance signals → Should produce 2 insights
- [ ] Verify insight confidence is the max across all grouped evidence

---

### Task 5: Flip Default to Persisted Insights

**Current Problem:** Feature flag defaults to old path (`usePersistedInsights = true` but old logic runs first in `body`).

**Solution:** After validation, change the default and clean up old code path.

**Files to change:**
- `AwarenessHost.swift`

**Implementation:**

**Step 5.1: Fix the conditional (body is backwards)**

```swift
// Current code has this backwards — fix it:
var body: some View {
    Group {
        if usePersistedInsights {
            AwarenessView(
                insights: sortedPersisted,
                onInsightTapped: { insight in
                    // Navigate to person/context...
                }
            )
            .environment(\._awarenessDismissAction, { insight in
                dismiss(insight)
            })
        } else {
            // Old path: EvidenceBackedInsight
            AwarenessView(
                insights: awarenessInsights,
                onInsightTapped: { insight in
                    whySheet = WhySheetItem(
                        title: insight.message,
                        evidenceIDs: insight.evidenceIDs
                    )
                }
            )
        }
    }
    // ... rest of view ...
}
```

**Step 5.2: After validation, remove old path**

Once Tasks 1-4 are complete and tested:

```swift
// Delete awarenessInsights computed property
// Delete EvidenceBackedInsight struct
// Delete SignalBucket enum
// Delete bestTargetName helper
// Delete bucketFor helper
// Remove feature flag and conditional

var body: some View {
    AwarenessView(
        insights: sortedPersisted,
        onInsightTapped: { insight in
            if let person = insight.samPerson {
                NotificationCenter.default.post(name: .samNavigateToPerson, object: person.id)
            } else if let context = insight.samContext {
                NotificationCenter.default.post(name: .samNavigateToContext, object: context.id)
            } else {
                let e = insight.evidenceIDs
                guard !e.isEmpty else { return }
                whySheet = WhySheetItem(
                    title: insight.message,
                    evidenceIDs: e
                )
            }
        }
    )
    .environment(\._awarenessDismissAction, { insight in
        dismiss(insight)
    })
    .sheet(item: $whySheet) { item in
        EvidenceDrillInSheet(title: item.title, evidenceIDs: item.evidenceIDs)
    }
}
```

**Testing:**
- [ ] Compare old vs. new Awareness side-by-side
- [ ] Verify all insights from old path appear in new path
- [ ] Verify navigation works (tap insight → opens Person/Context detail)
- [ ] Verify evidence drill-through works for unlinked insights

---

## Implementation Order

### Week 1 (Now)
1. ✅ Task 1: Improve duplicate prevention (2-3 hours)
2. ✅ Task 3: Improve message templates (1 hour)
3. ✅ Test duplicate prevention + messages

### Week 1 (continued)
4. ✅ Task 4: Evidence aggregation (2-3 hours)
5. ✅ Test aggregation logic thoroughly

### Week 2
6. ✅ Task 2: Wire automatic generation (2-3 hours)
7. ✅ End-to-end testing (generation → Awareness → navigation)
8. ✅ Side-by-side comparison (old vs. new)

### Week 2 (continued)
9. ✅ Task 5: Flip default after validation
10. ✅ Remove old code path
11. ✅ Update context.md

---

## Success Criteria

- [ ] Insights appear in Awareness within 3 seconds of evidence import
- [ ] Duplicate insights do not appear for same person+kind
- [ ] Tapping insight navigates to correct Person/Context detail
- [ ] Evidence drill-through works for unlinked insights
- [ ] Dismissed insights stay dismissed
- [ ] Message quality matches or exceeds old bucketing system
- [ ] No performance regression (generation happens in background)
- [ ] Old `EvidenceBackedInsight` code path is deleted

---

## Testing Checklist

### Duplicate Prevention
- [ ] Same signal, same person → 1 insight with multiple evidence IDs
- [ ] Different signals, same person → multiple insights
- [ ] Dismiss insight → create new evidence with same signal → insight stays dismissed

### Automatic Generation
- [ ] Import calendar events → insights appear within 3 seconds
- [ ] Import contacts → insights appear
- [ ] Rapid imports (10 in a row) → generation runs once (debounced)

### Message Quality
- [ ] Insight for Alice includes "(Alice Smith)"
- [ ] Insight for Smith Household includes "(Smith Household)"
- [ ] Unlinked insight has no target suffix

### Navigation
- [ ] Tap insight linked to person → opens PersonDetailHost
- [ ] Tap insight linked to context → opens ContextDetailView
- [ ] Tap unlinked insight → shows EvidenceDrillInSheet

### Aggregation
- [ ] 5 divorce signals for Alice → 1 insight with 5 evidence IDs
- [ ] Insight confidence = max across all grouped evidence
- [ ] `interactionsCount` = number of evidence items

---

## Rollback Plan

If issues arise:

1. **Immediate:** Flip feature flag back to old path (`usePersistedInsights = false`)
2. **Debug:** Check dev logs for generation errors
3. **Fix forward:** Address specific issue (duplicate prevention, etc.)
4. **Re-test:** Flip flag back to new path after fix

The feature flag exists specifically for this safety net.

---

## Phase 3 Preview

After Phase 2 is complete, Phase 3 will:

1. Replace `evidenceIDs: [UUID]` with `@Relationship var basedOnEvidence: [SamEvidenceItem]`
2. Add inverse relationship on `SamEvidenceItem`
3. Update `InsightCardView` to show/navigate to evidence via relationships
4. Update `InsightGenerator` to use relationships instead of ID arrays

Phase 3 is **purely additive** — it improves the data model but doesn't change any UI logic.

---

## Questions?

- **"Where do I start?"** → Task 1 (duplicate prevention)
- **"What's the risk?"** → Low — feature flag provides easy rollback
- **"How do I test?"** → Use the Testing Checklist above
- **"What if generation is slow?"** → Profiling + batch tuning (addressed in Phase 3)

