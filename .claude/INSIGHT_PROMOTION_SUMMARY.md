# Insight Promotion: Quick Reference

## Current State → Target State

### Today: Three Separate Systems

```
┌─────────────────────────────────────────────────────────────────┐
│ Person Detail                                                   │
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │ SamPerson                                                   │ │
│ │   var insights: [PersonInsight] ← embedded value type      │ │
│ │                                  (not persisted)            │ │
│ └─────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ Context Detail                                                  │
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │ SamContext                                                  │ │
│ │   var insights: [ContextInsight] ← embedded value type     │ │
│ │                                   (not persisted)           │ │
│ └─────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ Awareness Screen                                                │
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │ AwarenessHost                                               │ │
│ │   Computes EvidenceBackedInsight from signals on every     │ │
│ │   render. Not persisted. Has evidenceIDs but no            │ │
│ │   person/context link → can't navigate to detail.          │ │
│ └─────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

### Target: Unified Persisted Model

```
┌─────────────────────────────────────────────────────────────────┐
│ SwiftData                                                       │
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │ @Model class SamInsight                                     │ │
│ │   var samPerson: SamPerson?        ← relationship          │ │
│ │   var samContext: SamContext?      ← relationship          │ │
│ │   var basedOnEvidence: [SamEvidenceItem]                   │ │
│ │   var kind: InsightKind                                     │ │
│ │   var message: String                                       │ │
│ │   var confidence: Double                                    │ │
│ │   var createdAt: Date                                       │ │
│ │   var dismissedAt: Date?                                    │ │
│ └─────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
         ▲                        ▲                        ▲
         │                        │                        │
         │                        │                        │
┌────────┴────────┐      ┌───────┴────────┐      ┌───────┴────────┐
│ Person Detail   │      │ Context Detail │      │ Awareness      │
│                 │      │                │      │                │
│ @Query          │      │ @Query         │      │ @Query         │
│ person.insights │      │ context.insights│     │ all insights   │
└─────────────────┘      └────────────────┘      └────────────────┘
```

---

## Three-Phase Implementation

### Phase 1: Persist Person/Context Insights ✓ Start Here

**Goal:** Replace embedded value types with real `@Model` relationships

**Changes:**
- Add `@Model class SamInsight` to `SAMModels.swift`
- Change `SamPerson.insights` from `[PersonInsight]` to `@Relationship [SamInsight]`
- Change `SamContext.insights` from `[ContextInsight]` to `@Relationship [SamInsight]`
- Update `FixtureSeeder` to create `SamInsight` instances
- Update `BackupPayload` to serialize/deserialize insights

**Benefits:**
- Insights persist across app launches
- Can track dismissal state
- Foundation for evidence linkage

**Risk:** Low — isolated to Person/Context detail views

---

### Phase 2: Migrate Awareness to Query SamInsight

**Goal:** Replace runtime `EvidenceBackedInsight` with persisted insights

**Changes:**
- Create `InsightGenerator` service to convert signals → `SamInsight`
- Run generator after evidence import (background)
- Update `AwarenessHost` from computing insights to `@Query`ing them
- Add navigation from Awareness to Person/Context detail

**Benefits:**
- Awareness insights persist (no re-computation)
- Can navigate from Awareness to entity detail
- Single source of truth for all insights

**Risk:** Medium — changes Awareness data flow, needs generation timing decision

**Blocker:** Must decide when insights are generated (see "Open Questions")

---

### Phase 3: Add Evidence Relationships

**Goal:** Link insights to supporting evidence with `@Relationship`

**Changes:**
- Add `@Relationship var basedOnEvidence: [SamEvidenceItem]` to `SamInsight`
- Add inverse relationship `relatedInsights` to `SamEvidenceItem`
- Update `InsightCardView` to show/navigate to evidence
- Update `InsightGenerator` to link evidence when creating insights

**Benefits:**
- True explainability: click insight → see supporting evidence
- Evidence drill-through works from any view
- Insight confidence can update as evidence accumulates

**Risk:** Low — additive feature, doesn't break existing views

---

## Key Design Decisions Needed

### 1. When are insights generated?

| Option | Pros | Cons |
|--------|------|------|
| **A. During evidence import** | Simple, always up-to-date | Blocks import, slows UI |
| **B. Background job after import** | Fast import, async generation | Slight delay before insights appear |
| **C. On-demand when view appears** | No background work | Slow view loading |

**Recommendation:** Option B (background job)

---

### 2. How are insights updated?

| Option | Pros | Cons |
|--------|------|------|
| **A. Regenerate all on change** | Always current | Expensive, loses dismissal state |
| **B. Immutable with expiration** | Audit trail, preserves state | More storage, needs cleanup |
| **C. Update in place** | Efficient | Complex diff logic |

**Recommendation:** Option B (immutable) — set `dismissedAt`/`expiredAt`

---

### 3. Can insights span multiple entities?

**Example:** "Household structure change" affects both spouses + household context

| Option | Pros | Cons |
|--------|------|------|
| **A. One insight, multiple relationships** | No duplication | More complex queries |
| **B. Duplicate insight per entity** | Simple queries | Storage overhead |

**Recommendation:** Option A — change `samPerson`/`samContext` to arrays

---

### 4. What is Awareness navigation UX?

When user taps an insight in Awareness:

| Option | Pros | Cons |
|--------|------|------|
| **A. Navigate to entity detail** | Contextual, actionable | Can't see evidence |
| **B. Show evidence drill-in sheet** | Explainability | Extra tap to reach entity |
| **C. Smart: entity if linked, evidence if not** | Best of both | Complex logic |

**Recommendation:** Option C (smart routing)

---

## File Change Summary

### Phase 1 (Persist insights)

| File | Change Type | Complexity |
|------|-------------|------------|
| `SAMModels.swift` | Add `SamInsight` @Model | Medium |
| `SAMModels.swift` | Update `SamPerson`/`SamContext` relationships | Low |
| `SAMModelEnums.swift` | `SamInsight` conformance to `InsightDisplayable` | Low |
| `SAM_crmApp.swift` | Add to schema | Low |
| `FixtureSeeder.swift` | Create `SamInsight` instances | Medium |
| `BackupPayload.swift` | Add `BackupInsight` DTO | Medium |
| `PersonDetailHost.swift` | Change insight type | Low |
| `ContextDetailRouter.swift` | Change insight type | Low |

**Estimated Effort:** 4-6 hours

---

### Phase 2 (Awareness migration)

| File | Change Type | Complexity |
|------|-------------|------------|
| `InsightGenerator.swift` | **NEW** — signal → insight pipeline | High |
| `AwarenessHost.swift` | Replace computation with `@Query` | Medium |
| `AppShellView.swift` | Add navigation to Person/Context from Awareness | Medium |
| `CalendarImportCoordinator.swift` | Trigger insight generation after import | Low |

**Estimated Effort:** 6-8 hours

---

### Phase 3 (Evidence relationships)

| File | Change Type | Complexity |
|------|-------------|------------|
| `SAMModels.swift` | Add `basedOnEvidence` relationship | Low |
| `SamEvidenceItem` | Add inverse relationship | Low |
| `InsightCardView.swift` | Evidence drill-through UI | Medium |
| `InsightGenerator.swift` | Link evidence when creating insights | Low |

**Estimated Effort:** 3-4 hours

---

## Testing Strategy

### Phase 1 Tests

- [ ] **Fixture seeding:** Insights appear in Person/Context detail views
- [ ] **Persistence:** Insights survive app restart
- [ ] **Backup/restore:** Insights serialize and restore correctly
- [ ] **Relationship integrity:** Deleting a person cascades to insights
- [ ] **UI rendering:** `InsightCardView` displays `SamInsight` correctly

### Phase 2 Tests

- [ ] **Generation timing:** Insights appear after evidence import completes
- [ ] **Awareness query:** `@Query` returns correct insights
- [ ] **Navigation:** Tapping insight navigates to correct entity
- [ ] **Dismissal:** Dismissed insights disappear from Awareness
- [ ] **Performance:** Generation doesn't block UI (background)

### Phase 3 Tests

- [ ] **Evidence linkage:** Insights link to correct evidence items
- [ ] **Drill-through:** Clicking evidence in card opens detail
- [ ] **Evidence deletion:** Deleting evidence nullifies relationships
- [ ] **Multi-evidence:** Insights with 3+ evidence items render correctly

---

## Migration Risks & Mitigations

### Risk 1: Schema migration breaks existing data

**Mitigation:**
- Phase 1 is additive (new model + relationships)
- Old embedded arrays can coexist temporarily
- Test with fixture seeder before touching real data
- Keep backup/restore as escape hatch

### Risk 2: Insight generation performance

**Mitigation:**
- Run generation in background actor
- Batch evidence processing (don't generate for every single item)
- Add throttling (max N insights per second)
- Profile with Instruments if slow

### Risk 3: Awareness navigation breaks existing UX

**Mitigation:**
- Keep evidence drill-in sheet as fallback
- Add A/B test flag to toggle new navigation
- User testing with beta users first

### Risk 4: Duplicate insights flood the database

**Mitigation:**
- Check for existing insight before creating new one
- Use composite uniqueness: (personID, contextID, kind, message)
- Add cleanup job to expire stale insights

---

## Quick Start Checklist

### Before You Start

- [ ] Read `data-model.md` §10 (Insight design doc)
- [ ] Review current `PersonInsight` / `ContextInsight` usage
- [ ] Confirm navigation UX with stakeholders
- [ ] Back up current database

### Phase 1 Implementation Order

1. [ ] Add `SamInsight` @Model to `SAMModels.swift`
2. [ ] Add schema entry in `SAM_crmApp.swift`
3. [ ] Build and fix compiler errors
4. [ ] Update `SamPerson` and `SamContext` relationships
5. [ ] Make `SamInsight` conform to `InsightDisplayable`
6. [ ] Update `FixtureSeeder`
7. [ ] Run app, verify fixtures load
8. [ ] Update `PersonDetailHost` and `ContextDetailRouter`
9. [ ] Test Person/Context detail views
10. [ ] Add `BackupInsight` DTO
11. [ ] Test backup/restore
12. [ ] Commit Phase 1 ✓

---

## Success Metrics

### Phase 1
- ✓ All insight cards render correctly in Person/Context detail
- ✓ Insights persist after app restart
- ✓ Backup/restore works end-to-end

### Phase 2
- ✓ Awareness shows insights within 5 seconds of evidence import
- ✓ Tapping insight navigates to correct entity detail
- ✓ No performance regression on evidence import

### Phase 3
- ✓ Evidence drill-through loads in <1 second
- ✓ Insight confidence updates when evidence accumulates
- ✓ Explainability meets trust bar (clear "why" for every insight)

---

## Related Documentation

- `data-model.md` §10 — Design doc for Insight model
- `data-model.md` §13 — Insight explainability requirements
- `context.md` "Planned Tasks" — This task's context
- `INSIGHT_PROMOTION_PLAN.md` — Full implementation plan (this summary's source)

