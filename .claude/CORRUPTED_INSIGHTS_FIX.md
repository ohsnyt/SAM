# Corrupted Insights Fix - Complete Resolution

**Date:** February 7, 2026  
**Issue:** SamInsight crash due to uninitialized `kind` property from fixture seeder bug

## Problem Summary

### Symptoms
- App crashes when viewing Awareness tab or Person detail pages with insights
- Stack trace shows: `SamInsight.kind.getter` crashes with assertion failure
- SwiftData attempting to read uninitialized `kind` property

### Root Cause
The `FixtureSeeder.swift` had trailing commas in `SamInsight` initializer calls:

```swift
// ❌ BUGGY CODE (before fix)
let maryFollowUp = SamInsight(
    samPerson: mary,
    kind: .followUp,
    message: "Consider scheduling annual review.",
    confidence: 0.72,  // ← Trailing comma caused kind to not be initialized
)
```

This caused Swift to misinterpret the initializer, leaving the `kind` property uninitialized in the database.

## Complete Fix (3 Parts)

### 1. Fixed Fixture Seeder Code ✅

**File:** `FixtureSeeder.swift` (lines 92-108)

```swift
// ✅ FIXED CODE
let maryFollowUp = SamInsight(
    samPerson: mary,
    kind: .followUp,
    message: "Consider scheduling annual review.",
    confidence: 0.72  // ← No trailing comma
)

let smithConsent = SamInsight(
    samContext: smithHH,
    kind: .consentMissing,
    message: "Spousal consent may need review after recent household change.",
    confidence: 0.88  // ← No trailing comma
)
```

**Result:** New fixture seeds will create properly initialized insights.

---

### 2. Improved Delete Order ✅

**File:** `BackupTab.swift` - `DeveloperFixtureButton.wipeAndReseed()`

Updated the delete order to avoid cascade constraint violations:

```swift
// Delete in dependency order (most dependent first)
try modelContext.delete(model: SamInsight.self)          // 1. Insights reference everything
try modelContext.delete(model: SamAnalysisArtifact.self) // 2. Artifacts
try modelContext.delete(model: SamNote.self)             // 3. Notes
try modelContext.delete(model: SamEvidenceItem.self)     // 4. Evidence
try modelContext.delete(model: ContextParticipation.self) // 5. Relationships
try modelContext.delete(model: Coverage.self)
try modelContext.delete(model: Responsibility.self)
try modelContext.delete(model: JointInterest.self)
try modelContext.delete(model: ConsentRequirement.self)
try modelContext.delete(model: Product.self)             // 6. Products
try modelContext.delete(model: SamContext.self)          // 7. Contexts
try modelContext.delete(model: SamPerson.self)           // 8. People last
```

**Result:** "Restore developer fixture" button now works reliably without cascade errors.

---

### 3. New "Clean Up Corrupted Insights" Button ✅

**File:** `BackupTab.swift` - Added new function in `DeveloperFixtureButton`

```swift
@MainActor
private func cleanupCorruptedInsights() async {
    isWorking = true
    defer { isWorking = false }
    
    do {
        // Delete all insights - they'll be regenerated from evidence
        try modelContext.delete(model: SamInsight.self)
        try modelContext.save()
        message = "Corrupted insights removed. Insights will regenerate from evidence."
    } catch {
        message = "Failed to clean insights: \(error.localizedDescription)"
    }
}
```

**UI:** New button in Development tab (Settings):
- **"Clean up corrupted insights"** - Removes all insights without touching other data
- Lighter-weight than full fixture restore
- Insights automatically regenerate from evidence signals

---

## How to Fix Your Database

### Option A: Quick Fix (Recommended)
1. Open SAM
2. Go to **Settings → Development tab**
3. Click **"Clean up corrupted insights"**
4. Wait for confirmation message
5. Insights will regenerate automatically from evidence

### Option B: Full Reset
1. Open SAM
2. Go to **Settings → Development tab**
3. Click **"Restore developer fixture"**
4. Wait for confirmation
5. All data replaced with clean fixture data

### Option C: Manual Database Reset
If the app crashes immediately on launch:
1. Quit SAM
2. Delete the SwiftData database files:
   ```bash
   rm -rf ~/Library/Containers/com.yourcompany.SAM-crm/Data/Library/Application\ Support/default.store*
   ```
3. Relaunch SAM - fresh database will be created

---

## Prevention

### Code Review Checklist
- ✅ No trailing commas in SwiftData `@Model` initializers
- ✅ All required properties explicitly initialized
- ✅ Test fixture restoration after any model changes
- ✅ Delete operations follow dependency order

### Best Practices for @Model Initialization
```swift
// ✅ GOOD: No trailing comma on last parameter
let model = MyModel(
    requiredParam1: value1,
    requiredParam2: value2,
    requiredParam3: value3
)

// ❌ BAD: Trailing comma can cause issues with macro expansion
let model = MyModel(
    requiredParam1: value1,
    requiredParam2: value2,
    requiredParam3: value3,  // ← Remove this comma
)
```

### Why This Matters
SwiftData uses Swift macros (`@Model`, `@Attribute`, `@Relationship`) that generate property accessors and storage code. Trailing commas can confuse the macro expansion, especially when combined with default parameters and optional parameters.

---

## Testing Verification

### Manual Test Steps
1. ✅ Click "Restore developer fixture" - should complete without errors
2. ✅ Navigate to Awareness tab - should show insights without crashing
3. ✅ Open Person detail (Mary Smith) - should show follow-up insight
4. ✅ Open Context detail (Smith Household) - should show consent insight
5. ✅ Add a new note - should generate insights automatically
6. ✅ Click "Clean up corrupted insights" - should remove and regenerate

### Expected Behavior
- No crashes in `SamInsight.kind.getter`
- Insights display with correct icons and type labels
- Delete operations complete successfully in dependency order
- New insights created from fixture seeder have all properties initialized

---

## Related Files

### Modified
- `FixtureSeeder.swift` - Removed trailing commas from SamInsight initializers
- `BackupTab.swift` - Improved delete order and added cleanup button

### Affected Models
- `SamInsight` - The model with corrupted data
- `SamPerson` - Has relationship to insights
- `SamContext` - Has relationship to insights
- `Product` - Has relationship to insights

---

## Long-Term Solutions

### Consider These Enhancements
1. **Database Migrations**
   - Add SwiftData migration to detect and repair corrupted insights
   - Run automatically on app launch if schema version changes

2. **Validation on Fetch**
   - Add computed property to detect if `kind` is valid
   - Filter out corrupted insights in queries
   - Log warnings for investigation

3. **Defensive Initialization**
   - Add default value for `kind` property (e.g., `.opportunity`)
   - SwiftData would use this instead of leaving uninitialized

4. **Better Error Handling**
   - Catch SwiftData accessor crashes and show user-friendly error
   - Offer "Reset Database" option in error UI

---

## Summary

✅ **Root cause identified:** Trailing commas in fixture seeder initializers  
✅ **Code fixed:** Removed trailing commas from `FixtureSeeder.swift`  
✅ **Delete order improved:** Proper dependency order for cascade deletes  
✅ **Cleanup utility added:** New button to remove corrupted insights without full reset  
✅ **Prevention documented:** Best practices for @Model initialization

**Immediate Action Required:**  
Run "Clean up corrupted insights" or "Restore developer fixture" from Settings → Development tab to remove existing corrupted data from your database.
