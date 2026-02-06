# Phase 3 Build Checklist

## Pre-Build Verification

- ✅ `SAMModels.swift`: `SamInsight` has `basedOnEvidence` relationship
- ✅ `SAMModels.swift`: `SamEvidenceItem` has `supportingInsights` inverse relationship
- ✅ `InsightGenerator.swift`: All methods use relationships instead of `evidenceIDs`
- ✅ `BackupPayload.swift`: `BackupInsight` DTO defined and integrated
- ✅ `BackupPayload.swift`: Restore logic re-links insight relationships

## Build Steps

1. **Clean build folder**: Product → Clean Build Folder (⇧⌘K)
2. **Build**: Product → Build (⌘B)
3. **Check for errors**: Verify no compilation errors

## Expected Warnings

None expected. If you see warnings about:
- `evidenceIDs` not found → Good, this confirms the removal
- `interactionsCount` parameter → Check that all `SamInsight()` init calls removed this parameter

## Post-Build Testing

### Manual Testing (Developer Build)

1. **Fresh Install**
   - Delete app from Applications
   - Clean build folder
   - Build and run
   - Verify FixtureSeeder creates insights with evidence relationships
   - Check Awareness tab shows insights with correct interaction counts

2. **Insight Generation**
   - Import a calendar event with signals (e.g., event with "divorce" keyword)
   - Verify insight is created
   - Check that `insight.basedOnEvidence` contains the evidence item
   - Verify `insight.interactionsCount` equals `basedOnEvidence.count`

3. **Deduplication**
   - Create duplicate insights manually (via developer tools)
   - Run "Deduplicate Insights" button in Settings → Development
   - Verify duplicates are merged and evidence is combined

4. **Backup/Restore**
   - Create some insights with evidence
   - Export backup (Settings → Backup → Export)
   - Delete app data (or use "Restore developer fixture")
   - Restore from backup
   - Verify insights are restored with correct evidence relationships

5. **Evidence Deletion**
   - Create an insight with evidence
   - Delete the evidence item from Inbox
   - Verify insight still exists but `basedOnEvidence` is empty
   - Verify no crash or data corruption

## Known Issues / Expected Behavior

1. **Existing insights lose evidence links**
   - On first launch after upgrading, existing insights will have empty `basedOnEvidence` arrays
   - This is expected behavior for the automatic schema migration
   - `interactionsCount` will show 0 for these insights
   - Solution: Run "Restore developer fixture" or delete and reimport evidence

2. **Schema migration is one-way**
   - Cannot downgrade to previous version without data loss
   - Backup files from pre-Phase-3 builds will fail to restore (version mismatch)

## If Build Fails

### Common Issues

1. **"Cannot find 'evidenceIDs' in scope"**
   - Check all files that might reference the old property
   - Search project for `evidenceIDs` and update any remaining references

2. **"Type 'SamInsight' has no member 'interactionsCount' setter"**
   - It's now a computed property
   - Remove any code trying to set it directly
   - Check InsightGenerator and FixtureSeeder

3. **"Missing argument for parameter 'basedOnEvidence'"**
   - Update `SamInsight()` init calls to use new signature
   - Replace `evidenceIDs: [...]` with `basedOnEvidence: [...]`

4. **SwiftData relationship errors at runtime**
   - Check that inverse relationship is correctly specified
   - Verify `@Relationship` syntax matches documentation
   - Ensure both sides of relationship are properly annotated

## Success Criteria

- ✅ App builds without errors or warnings
- ✅ App launches without crashes
- ✅ Insights display with correct interaction counts
- ✅ Insight generation creates proper relationships
- ✅ Backup/restore preserves evidence links
- ✅ Evidence deletion doesn't crash insights
- ✅ Deduplication merges evidence correctly

## Next Steps After Successful Build

1. Write Swift Testing tests for relationship behavior
2. Test edge cases (empty evidence, many-to-many relationships)
3. Validate backup file format version bump (if needed)
4. Update user-facing documentation (if any)
5. Consider adding migration notes to release notes
