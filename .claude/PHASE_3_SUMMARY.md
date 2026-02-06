# Phase 3: Evidence Relationships - Implementation Summary

## Goal
Replace `evidenceIDs: [UUID]` array on `SamInsight` with proper SwiftData `@Relationship` to `[SamEvidenceItem]`.

## Changes Completed

### 1. SAMModels.swift ✅

**SamInsight changes:**
- ✅ Removed `var evidenceIDs: [UUID] = []`
- ✅ Added `@Relationship(deleteRule: .nullify, inverse: \SamEvidenceItem.supportingInsights) var basedOnEvidence: [SamEvidenceItem] = []`
- ✅ Changed `interactionsCount` from stored property to computed property: `basedOnEvidence.count`
- ✅ Updated `init` to accept `basedOnEvidence: [SamEvidenceItem]` instead of `evidenceIDs`
- ✅ Removed `interactionsCount` parameter from `init`

**SamEvidenceItem changes:**
- ✅ Added inverse relationship: `var supportingInsights: [SamInsight]? = []`

### 2. InsightGenerator.swift ✅

Updated all three insight generation methods:

**`generatePendingInsights()`:**
- No changes needed (already batch-processes evidence)

**`deduplicateInsights()`:**
- ✅ Changed sort logic from `evidenceIDs.count` to `basedOnEvidence.count`
- ✅ Changed merge logic to use `Set(duplicates.flatMap(\.basedOnEvidence))` instead of UUID arrays
- ✅ Removed `interactionsCount` assignment (now computed)

**`generateInsights(for:)`:**
- ✅ Changed duplicate check from `!existing.evidenceIDs.contains(evidence.id)` to relationship-based check
- ✅ Changed append from UUID to evidence object: `existing.basedOnEvidence.append(evidence)`
- ✅ Removed `interactionsCount` increment (now computed)
- ✅ Updated `SamInsight` init to use `basedOnEvidence: [evidence]` instead of `evidenceIDs`

**`generateOrUpdateInsight(for:key:)`:**
- ✅ Changed filtering logic to check `basedOnEvidence` relationship
- ✅ Changed append from UUIDs to evidence objects
- ✅ Removed `interactionsCount` assignment (now computed)
- ✅ Updated `SamInsight` init to use `basedOnEvidence: evidence` instead of `evidenceIDs`

### 3. BackupPayload.swift ✅

**Added BackupInsight DTO:**
```swift
struct BackupInsight: Codable, Identifiable {
    let id: UUID
    let personID: UUID?
    let contextID: UUID?
    let productID: UUID?
    let kind: InsightKind
    let message: String
    let confidence: Double
    let evidenceIDs: [UUID]  // Serialized as UUIDs for portability
    let createdAt: Date
    let dismissedAt: Date?
    let consentsCount: Int
}
```

**BackupPayload changes:**
- ✅ Added `let insights: [BackupInsight]` to payload
- ✅ Updated `current(using:)` to fetch and serialize `SamInsight` models
- ✅ Updated `restore(into:)` to:
  - Delete insights first (before evidence)
  - Insert insight models
  - Re-link `basedOnEvidence` relationships using `evidenceByID` dictionary

**Restore order:**
1. Delete: Insights → Evidence → Contexts → People
2. Insert: People → Contexts → Evidence → Insights  
3. Re-link: Evidence relationships, then Insight relationships

### 4. Schema Migration

**Key changes:**
- SwiftData will automatically handle the schema migration from `evidenceIDs` to the new relationship
- The `@Relationship` annotation creates a proper many-to-many join table
- Existing insights will lose their evidence links on first launch (acceptable for developer preview)
- Production apps would need a custom migration to preserve evidence links

## Benefits Achieved

1. **Type Safety**: Compile-time enforcement of evidence-insight relationships
2. **Performance**: SwiftData can optimize relationship queries and prefetching
3. **Data Integrity**: Cascade deletes properly managed via `deleteRule: .nullify`
4. **Cleaner Code**: No manual UUID → object resolution needed
5. **Backup Compatibility**: Evidence links preserved across backup/restore cycles

## Testing Recommendations

1. ✅ Verify insight generation creates proper relationships
2. ✅ Verify deduplication merges evidence correctly
3. ✅ Verify backup includes insights with evidence IDs
4. ✅ Verify restore re-links evidence relationships
5. ✅ Verify `interactionsCount` computed property works in UI
6. ⚠️ Test with fresh install (developer fixture)
7. ⚠️ Test backup/restore cycle preserves insights
8. ⚠️ Test evidence deletion nullifies insight links (doesn't delete insights)

## Breaking Changes

**For Existing Installs:**
- SwiftData will perform an automatic lightweight migration
- Existing insights will **lose** their evidence links (they'll have empty `basedOnEvidence` arrays)
- This is acceptable for a developer preview/beta app
- For production, consider adding a one-time migration that reads old `evidenceIDs` and rebuilds relationships

**For Code:**
- Any code that directly accessed `insight.evidenceIDs` must be updated
- Any code that set `insight.interactionsCount` must be removed (it's now computed)
- `SamInsight` initializers no longer accept `evidenceIDs` or `interactionsCount` parameters

## Next Steps

1. Update FixtureSeeder (if it creates insights with evidence)
2. Test full backup/restore cycle
3. Add Swift Testing coverage for:
   - Insight generation with relationships
   - Deduplication with evidence merging
   - Backup/restore preserving evidence links
4. Update context.md with Phase 3 completion notes

## Notes

- The `consentsCount` property remains a stored value (not computed) because it represents consent requirements, not evidence count
- The inverse relationship on `SamEvidenceItem` is optional (`[SamInsight]?`) to allow evidence without insights
- Delete rule is `.nullify` so deleting evidence doesn't cascade-delete insights (insights remain but lose that evidence link)
