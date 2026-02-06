# Insight Promotion: Preparation Complete ✅

You are now fully prepared to implement **Planned Task #1: Promote Insights to a first-class @Model**.

---

## What I've Prepared for You

### 📋 Four comprehensive documents:

1. **`INSIGHT_PROMOTION_PLAN.md`** — Complete technical specification
   - Current state analysis (three parallel insight systems)
   - Design doc alignment (unified `Insight` model from §10, §13)
   - Three-phase implementation plan
   - Open questions and design decisions
   - Migration checklist
   - Success criteria

2. **`INSIGHT_PROMOTION_SUMMARY.md`** — Quick reference guide
   - Visual architecture diagrams (before/after)
   - Phase overviews with effort estimates
   - Key design decisions with trade-off tables
   - File change summary
   - Testing strategy
   - Risk mitigation

3. **`PHASE_1_IMPLEMENTATION_GUIDE.md`** — Step-by-step tutorial
   - Numbered steps with exact code changes
   - File locations and context
   - Verification checklists after each step
   - Testing procedures
   - Common issues and fixes
   - Rollback plan

4. **`INSIGHT_PROMOTION_SUMMARY.md`** (this file) — Quick navigation

---

## Critical Finding: Scope Resolution Required

### The Core Question

Your design doc (`data-model.md §10`) calls for a **single unified `Insight` @Model** shared by:
- Person/Context detail views
- Awareness dashboard

But the current implementation shows a **semantic split**:

| System | Purpose | Evidence Link | Navigation |
|--------|---------|---------------|------------|
| **Person/Context Insights** | "What does this entity need?" | No evidence drill-through | N/A (already on detail view) |
| **Awareness Insights** | "What needs attention in my book?" | Evidence drill-through is core | Navigate to entity |

**The Problem:**
`EvidenceBackedInsight` (Awareness) has `evidenceIDs` but **no person/context reference** → can't navigate to detail view.

### Three Approaches

#### Option 1: Unified (Recommended — Matches Design Doc)
- One `SamInsight` model serves both use cases
- Awareness materializes insights for all evidence (even unlinked)
- Phase 1: Persist Person/Context insights
- Phase 2: Migrate Awareness to query `SamInsight`
- **Pro:** Single source of truth, design doc alignment
- **Con:** More work upfront

#### Option 2: Hybrid
- Keep `EvidenceBackedInsight` as runtime-only for Awareness
- Add `SamInsight` for Person/Context only
- **Pro:** Awareness stays lightweight
- **Con:** Two parallel systems forever

#### Option 3: Signal-based
- Promote `EvidenceSignal` to `@Model` first
- Generate `SamInsight` only when evidence is linked to an entity
- **Pro:** Gradual migration
- **Con:** Duplicates signal storage

**My Recommendation:** Option 1 (Unified), implemented in three phases as documented.

---

## Recommended Path Forward

### 1. Decision Meeting (15-30 minutes)

Review with your team:
- **Unified vs. Hybrid approach** (see above)
- **Awareness navigation UX:** Navigate to entity or show evidence? (see design decisions table)
- **Insight generation timing:** During import, background job, or on-demand? (see Phase 2 section)

### 2. Start Phase 1 (4-6 hours)

Follow `PHASE_1_IMPLEMENTATION_GUIDE.md` step-by-step:
- Add `SamInsight` @Model
- Convert Person/Context relationships
- Update fixtures and backup
- Test end-to-end

**Safe to start immediately** — Phase 1 doesn't touch Awareness, so rollback is easy.

### 3. Validate Phase 1

Before moving to Phase 2:
- [ ] Insights persist across launches
- [ ] Backup/restore works
- [ ] No performance regression
- [ ] Detail views render correctly

### 4. Design Phase 2 Pipeline

Once Phase 1 is stable:
- Read Phase 2 section in `INSIGHT_PROMOTION_PLAN.md`
- Prototype `InsightGenerator` actor
- Decide on generation triggers
- Test duplicate prevention

### 5. Implement Phase 2 (6-8 hours)

Migrate Awareness from runtime computation to `@Query<SamInsight>`:
- Wire up insight generation
- Update `AwarenessHost` to query DB
- Add navigation to Person/Context detail

### 6. Add Evidence Links in Phase 3 (3-4 hours)

Replace `evidenceIDs: [UUID]` with `@Relationship var basedOnEvidence: [SamEvidenceItem]`:
- Add relationship to `SamInsight`
- Add inverse to `SamEvidenceItem`
- Update `InsightCardView` for drill-through

---

## Quick Start (If You Want to Start Now)

```bash
# 1. Read the overview
open INSIGHT_PROMOTION_SUMMARY.md

# 2. Follow the step-by-step guide
open PHASE_1_IMPLEMENTATION_GUIDE.md

# 3. Keep the full plan handy for reference
open INSIGHT_PROMOTION_PLAN.md
```

**Start at Step 1 of Phase 1** — it's isolated and safe to implement.

---

## Design Decisions Documented

I've documented trade-offs for:

### 1. When are insights generated?
- **During import** (simple, blocks UI)
- **Background job** (fast, slight delay) ← Recommended
- **On-demand** (lazy, slow view loading)

### 2. How are insights updated?
- **Regenerate all** (simple, loses state)
- **Immutable with expiration** (audit trail) ← Recommended
- **Update in place** (complex diff logic)

### 3. Can insights span multiple entities?
- **One insight, multiple relationships** (no duplication) ← Recommended
- **Duplicate per entity** (simple queries)

### 4. Awareness navigation UX?
- **Always navigate to entity** (contextual)
- **Always show evidence** (explainability)
- **Smart routing** (entity if linked, evidence otherwise) ← Recommended

See `INSIGHT_PROMOTION_SUMMARY.md` for full trade-off tables.

---

## Key Architecture Insights

### Current State
```
SamPerson
  var insights: [PersonInsight]  ← embedded, not persisted

SamContext
  var insights: [ContextInsight] ← embedded, not persisted

AwarenessHost
  computes EvidenceBackedInsight from signals on every render
  (has evidenceIDs but no person/context link)
```

### Target State (After All 3 Phases)
```
@Model class SamInsight
  var samPerson: SamPerson?        ← relationship
  var samContext: SamContext?      ← relationship
  var basedOnEvidence: [SamEvidenceItem] ← relationship
  
SamPerson.insights: [SamInsight]   ← relationship (cascading delete)
SamContext.insights: [SamInsight]  ← relationship (cascading delete)
AwarenessHost queries SamInsight   ← @Query, no computation
```

---

## Files That Will Change (Phase 1 Only)

| File | What Changes | Complexity |
|------|--------------|------------|
| `SAMModels.swift` | Add `SamInsight` @Model, update relationships | Medium |
| `SAMModelEnums.swift` | Add `InsightDisplayable` conformance | Low |
| `SAM_crmApp.swift` | Add to schema | Low |
| `FixtureSeeder.swift` | Create `SamInsight` instances | Medium |
| `BackupPayload.swift` | Add DTO, update current/restore | Medium |
| `PersonDetailHost.swift` | Change type to `[SamInsight]` | Low |
| `ContextDetailRouter.swift` | Change type to `[SamInsight]` | Low |
| `PersonDetailModel.swift` | Update property type | Low |
| `ContextDetailModel.swift` | Update property type | Low |

**Total estimated effort for Phase 1:** 4-6 hours

---

## What's NOT Changing in Phase 1

✅ These stay exactly the same:
- `AwarenessHost` (still computes `EvidenceBackedInsight`)
- `InsightCardView` (already generic over `InsightDisplayable`)
- `InsightGeneratorV1` (still produces signals)
- `EvidenceRepository` (no insight generation yet)
- All Inbox views
- All other evidence-related code

**This is why Phase 1 is low-risk** — it's isolated to Person/Context detail views.

---

## Testing Checklist (Phase 1)

After implementation:
- [ ] Fixtures create insights correctly
- [ ] Person detail shows insights
- [ ] Context detail shows insights
- [ ] Insights persist after app restart
- [ ] Backup exports insights
- [ ] Restore imports insights with correct relationships
- [ ] Deleting a person cascades to insights
- [ ] No performance regression
- [ ] No UI layout issues

---

## Known Gotchas Documented

From your `context.md` "Resolved Gotchas" section, I've incorporated:
- Schema must include every @Model type (you'll add `SamInsight.self`)
- Backup restore order matters (insights after people/contexts, before evidence)
- Previews should use real types, not mocks (`SamInsight` already works)
- `@Relationship` bidirectional setup (person.insights automatic when you insert insight)

---

## Next Actions

### Immediate (Today)
1. ✅ Read `INSIGHT_PROMOTION_SUMMARY.md` (quick overview)
2. ✅ Confirm approach with team (unified vs. hybrid)
3. ⏳ Start Phase 1 following `PHASE_1_IMPLEMENTATION_GUIDE.md`

### This Week
4. ⏳ Complete Phase 1 implementation
5. ⏳ Test thoroughly (use checklist above)
6. ⏳ Commit Phase 1 ✓

### Next Week
7. ⏳ Design Phase 2 insight generation pipeline
8. ⏳ Implement Phase 2 (Awareness migration)
9. ⏳ Add Phase 3 evidence relationships

---

## Questions? Start Here:

- **"How do I start?"** → Open `PHASE_1_IMPLEMENTATION_GUIDE.md`, follow Step 1
- **"What's the big picture?"** → Read `INSIGHT_PROMOTION_SUMMARY.md`
- **"What are the edge cases?"** → See "Open Questions" in `INSIGHT_PROMOTION_PLAN.md`
- **"How do I test?"** → See "Testing Strategy" in `INSIGHT_PROMOTION_SUMMARY.md`
- **"What if it breaks?"** → See "Rollback Plan" in `PHASE_1_IMPLEMENTATION_GUIDE.md`

---

## Success Metrics (All 3 Phases)

### Phase 1 Success
- ✓ Insights persist across launches
- ✓ Detail views render correctly
- ✓ Backup/restore works

### Phase 2 Success
- ✓ Awareness shows insights within 5 seconds of import
- ✓ Tapping insight navigates to entity
- ✓ No performance regression

### Phase 3 Success
- ✓ Evidence drill-through works everywhere
- ✓ Insights update as evidence accumulates
- ✓ Explainability meets trust bar

---

## Final Notes

### Why This Matters (From Your Agent.md)

> **SAM's AI should feel like a thoughtful junior partner—not an automation engine.**

Persisting insights is essential for:
- **Trust:** Users can dismiss insights and they stay dismissed
- **Explainability:** Every insight links back to supporting evidence
- **Context:** Awareness can navigate to the entity (person/context) for action
- **Memory:** Insights don't disappear on every app restart

### Alignment with Design Doc

Your `data-model.md §10` describes:
```swift
@Model
final class Insight {
    var samContact: SamContact?
    var context: Context?
    var basedOnInteractions: [Interaction]
    var basedOnConsents: [ConsentRequirement]
    var dismissedAt: Date?
}
```

This implementation **matches that vision exactly**, with pragmatic phase splits to de-risk the migration.

### Platform Alignment (macOS Native)

This keeps SAM unmistakably Mac-native:
- SwiftData for persistence (not JSON files)
- `@Model` and `@Relationship` (not manual SQL)
- Bidirectional relationships (not foreign keys)
- Observable state (not notification center)

---

## You're Ready to Start ✅

All design decisions are documented. All trade-offs are analyzed. All steps are numbered.

**Begin Phase 1 implementation whenever you're ready.**

Good luck! 🚀

