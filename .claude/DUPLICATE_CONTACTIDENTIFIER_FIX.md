# 🔧 Duplicate ContactIdentifier Fix Guide

## Your Specific Problem

**Symptom:** Two `SamPerson` records share the same `contactIdentifier`, both showing the same contact photo from Contacts.app, but they remain as separate people in your database.

**Root Cause:** Permission race condition

### The Race Condition Explained

```
Your App's Permission Flow:
┌─────────────────────────────────────────────────┐
│ 1. App launches                                 │
│ 2. Your code requests Calendar + Contacts       │  ← First permission request
│ 3. User grants BOTH permissions                 │
│ 4. Contacts are imported, creating SamPerson(s) │
└─────────────────────────────────────────────────┘
                     ↓
┌─────────────────────────────────────────────────┐
│ 5. ContactsSyncManager.startObserving() runs    │
│ 6. Checks permission status                     │  ← Status is .authorized (already granted!)
│ 7. Skips to validation (bypasses deduplication) │  ❌ PROBLEM: Duplicates not cleaned
└─────────────────────────────────────────────────┘
                     ↓
┌─────────────────────────────────────────────────┐
│ 8. System shows SECOND permission dialog        │  ← macOS sometimes shows this
│ 9. User grants again (redundantly)              │
│ 10. More contacts imported                      │  ❌ Creates MORE duplicates
└─────────────────────────────────────────────────┘
```

### Why Deduplication Didn't Run

In `ContactsSyncManager.startObserving()`, there are two code paths:

**Path A (Working):** Permission not yet granted
```swift
if status == .notDetermined {
    // Request permission
    _ = try await store.requestAccess(for: .contacts)
    
    // ✅ Deduplication runs here
    if ContactSyncConfiguration.deduplicateAfterPermissionGrant {
        let cleaner = DuplicatePersonCleaner(modelContext: modelContext)
        try? cleaner.cleanAllDuplicates()
    }
}
```

**Path B (Broken):** Permission already granted elsewhere
```swift
if status == .authorized {
    // ❌ Old code went straight to validation
    await validateAllLinkedContacts()  // No deduplication!
}
```

## The Fix (Already Implemented)

Your codebase **already has the fix**, but you need to verify the configuration:

### Step 1: Check ContactSyncConfiguration.swift

Open `ContactSyncConfiguration.swift` and verify:

```swift
/// This setting fixes the race condition
static let deduplicateOnEveryLaunch: Bool = true  // ← Must be TRUE
```

If it's `false`, change it to `true`.

### Step 2: Verify the Fixed Code

In `ContactsSyncManager.swift` (around line 90), you should see:

```swift
if status == .authorized {
    // ✅ NEW CODE: Always deduplicate on startup when permission exists
    if ContactSyncConfiguration.deduplicateOnEveryLaunch {
        let cleaner = DuplicatePersonCleaner(modelContext: modelContext)
        let dedupeCount = try cleaner.cleanAllDuplicates()
        // ...
    }
    
    await validateAllLinkedContacts()
}
```

This ensures deduplication runs **every time the app launches**, regardless of how permission was granted.

## How to Fix Your Existing Duplicates

You have three options:

### Option 1: Restart the App (Automatic)

If `deduplicateOnEveryLaunch = true`:

1. Restart your app
2. Deduplication will run automatically on startup
3. Check the console for: `"📱 ContactsSyncManager: Merged X duplicate people on startup"`

### Option 2: Use the Diagnostic UI (Recommended)

Add this to your app (e.g., in a settings or debug menu):

```swift
import SwiftUI

Button("Fix Duplicate Contacts") {
    showingDiagnostics = true
}
.sheet(isPresented: $showingDiagnostics) {
    DuplicateContactDiagnosticView()
}
```

This gives you:
- ✅ Visual report of all duplicates
- ✅ One-tap fix button
- ✅ Permission race condition diagnosis
- ✅ Before/after comparison

### Option 3: Manual Code (For Testing)

In any SwiftUI view with `@Environment(\.modelContext)`:

```swift
Button("Fix Duplicates Now") {
    Task {
        let cleaner = DuplicatePersonCleaner(modelContext: modelContext)
        let count = try? cleaner.cleanAllDuplicates()
        print("Merged \(count ?? 0) duplicates")
    }
}
```

Or in console/debugging:

```swift
let diagnostics = ContactDuplicateDiagnostics(modelContext: modelContext)

// Print report
try diagnostics.printReport()
try diagnostics.printPermissionDiagnosis()

// Fix duplicates
let cleaner = DuplicatePersonCleaner(modelContext: modelContext)
let count = try cleaner.cleanAllDuplicates()
print("Fixed \(count) duplicates")
```

## Verification: Confirm the Problem is Fixed

### Before Running the Fix

Run this diagnostic:

```swift
let diagnostics = ContactDuplicateDiagnostics(modelContext: modelContext)
let duplicates = try diagnostics.findDuplicatesByContactIdentifier()

print("Found \(duplicates.count) duplicate contactIdentifier(s)")
for (identifier, people) in duplicates {
    print("  • \(identifier): \(people.count) people")
    for person in people {
        print("    - \(person.displayName) (ID: \(person.id))")
    }
}
```

**Expected output (your current state):**
```
Found 1 duplicate contactIdentifier(s)
  • ABC123: 2 people
    - John Smith (ID: ...)
    - John Smith (ID: ...)
```

### After Running the Fix

Run the same diagnostic:

**Expected output (after fix):**
```
Found 0 duplicate contactIdentifier(s)
✅ No duplicates found! All contactIdentifiers are unique.
```

## How Deduplication Works

The `DuplicatePersonCleaner` merges duplicates like this:

1. **Find duplicates by contactIdentifier:**
   ```swift
   if person.contactIdentifier == candidate.contactIdentifier {
       // These are definitely duplicates
   }
   ```

2. **Choose survivor:**
   - Keeps the person with more relationships
   - Prefers the one with a `contactIdentifier` (in case one was unlinked)

3. **Merge relationships:**
   - Moves all participations, coverages, consents to survivor
   - Transfers role badges, context chips, insights
   - Combines alert counts

4. **Delete duplicate:**
   - SwiftData automatically updates all relationships
   - The duplicate is permanently removed

## Preventing Future Duplicates

### Configure for Production

In `ContactSyncConfiguration.swift`:

```swift
// Always deduplicate on launch (handles race conditions)
static let deduplicateOnEveryLaunch: Bool = true

// Also deduplicate after permission grant (belt-and-suspenders)
static let deduplicateAfterPermissionGrant: Bool = true

// Debug logging (disable in production)
static let enableDebugLogging: Bool = false  // Set to true for debugging
```

### Monitor for Duplicates

Add this to your app's health check or admin panel:

```swift
func checkForDuplicates() async -> Int {
    let diagnostics = ContactDuplicateDiagnostics(modelContext: modelContext)
    let duplicates = try? diagnostics.findDuplicatesByContactIdentifier()
    return duplicates?.count ?? 0
}

// In your UI
Text("Health: \(duplicateCount == 0 ? "✅" : "⚠️ \(duplicateCount) duplicates")")
    .task {
        duplicateCount = await checkForDuplicates()
    }
```

### Best Practices

1. **Always enable `deduplicateOnEveryLaunch`** — Catches duplicates from any source
2. **Run deduplication after imports** — The `ContactsImporter` already does this
3. **Use `DuplicateContactDiagnosticView`** — Make it accessible to testers/users
4. **Monitor console output** — Watch for deduplication messages in logs

## Troubleshooting

### "Deduplication runs but duplicates remain"

Check if the `contactIdentifier` values are **actually identical**:

```swift
let people = try modelContext.fetch(FetchDescriptor<SamPerson>())
for person in people where person.contactIdentifier != nil {
    print("\(person.displayName): \(person.contactIdentifier!)")
}
```

If they're different identifiers, they're legitimately different contacts.

### "Deduplication doesn't run on startup"

Check:

1. Is `ContactSyncConfiguration.deduplicateOnEveryLaunch = true`?
2. Is `ContactsSyncManager.startObserving()` being called?
3. Is Contacts permission granted?

Enable debug logging to see:

```swift
// In ContactSyncConfiguration.swift
static let enableDebugLogging: Bool = true

// Console will show:
// "📱 ContactsSyncManager: Checking for duplicates on launch..."
// "📱 ContactsSyncManager: Merged X duplicate people on startup"
```

### "Deduplication runs but wrong person is kept"

The merge logic prioritizes:
1. Person with `contactIdentifier` (if one is unlinked)
2. Person with more relationships

If you need custom logic, modify `DuplicatePersonCleaner.findDuplicates()`.

## Summary: Your Action Plan

✅ **Immediate fix for existing duplicates:**

1. Verify `ContactSyncConfiguration.deduplicateOnEveryLaunch = true`
2. Restart app (deduplication runs automatically)
3. Or use `DuplicateContactDiagnosticView` for visual confirmation

✅ **Prevent future duplicates:**

1. Keep `deduplicateOnEveryLaunch = true`
2. Keep `deduplicateAfterPermissionGrant = true`
3. Don't disable validation on startup

✅ **Ongoing monitoring:**

1. Add `DuplicateContactDiagnosticView` to settings/debug menu
2. Enable debug logging during development
3. Check console for deduplication messages

---

**Files Created:**
- ✅ `ContactSyncConfiguration.swift` — Centralized configuration
- ✅ `ContactDuplicateDiagnostics.swift` — Diagnostic utilities
- ✅ `DuplicateContactDiagnosticView.swift` — UI for finding/fixing duplicates
- ✅ `DUPLICATE_CONTACTIDENTIFIER_FIX.md` — This guide

**Next Step:** Restart your app or open `DuplicateContactDiagnosticView` to fix the duplicates!
