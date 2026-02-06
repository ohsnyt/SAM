# Insight Promotion to First-Class @Model — Implementation Plan

**Status:** Preparation Phase  
**Date:** February 5, 2026  
**Goal:** Convert embedded `PersonInsight` and `ContextInsight` value types into a unified, persisted `SamInsight` `@Model` class that serves both Person/Context detail views and the Awareness screen.

---

## Current State Analysis

### Three Parallel Insight Systems

Today, SAM has **three separate insight representations**:

1. **`PersonInsight`** (embedded value type on `SamPerson.insights`)
   - `struct PersonInsight: Identifiable, Codable, Hashable`
   - Properties: `kind`, `message`, `confidence`, `interactionsCount`, `consentsCount`
   - Stored as an embedded array on `SamPerson`
   - Not persisted across app launches
   - No evidence linkage

2. **`ContextInsight`** (embedded value type on `SamContext.insights`)
   - `struct ContextInsight: Identifiable, Codable, Hashable`
   - Identical shape to `PersonInsight`
   - Stored as an embedded array on `SamContext`
   - Same limitations: not persisted, no evidence linkage

3. **`EvidenceBackedInsight`** (runtime-only, used by `AwarenessHost`)
   - `struct EvidenceBackedInsight: InsightDisplayable, Hashable`
   - Properties: `kind`, `typeDisplayName`, `message`, `confidence`, `interactionsCount`, `consentsCount`, `evidenceIDs`
   - Computed fresh on every view render from `SamEvidenceItem.signals`
   - **Critical:** Carries `evidenceIDs: [UUID]` for drill-through to supporting evidence
   - **Problem:** Has no `samContact` or `context` reference, so there's nothing to navigate to from Awareness

### Design Doc Vision (§10, §13)

The design doc (`data-model.md §10`) describes a **unified `Insight` @Model**:

```swift
@Model
final class Insight {
    @Attribute(.unique) var id: UUID

    var samContact: SamContact?
    var context: Context?
    var product: Product?

    var type: InsightType
    var message: String
    var confidence: Double

    var basedOnInteractions: [Interaction]
    var basedOnConsents: [ConsentRequirement]

    var createdAt: Date
    var dismissedAt: Date?
}
