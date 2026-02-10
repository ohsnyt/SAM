# Database Cleanup with Automatic Sync Trigger

**Date:** February 7, 2026  
**Enhancement:** Automatic Calendar & Contacts sync after database cleanup operations

## Overview

Enhanced the Development tab database utilities to automatically trigger Calendar and Contacts import after cleaning or restoring data. This ensures the app repopulates with fresh evidence and insights immediately after cleanup operations.

## Implementation

### 1. Clean Up Corrupted Insights

**Function:** `DeveloperFixtureButton.cleanupCorruptedInsights()`

```swift
@MainActor
private func cleanupCorruptedInsights() async {
    // 1. Delete corrupted insights
    try modelContext.delete(model: SamInsight.self)
    try modelContext.save()
    
    // 2. Trigger Calendar & Contacts sync
    CalendarImportCoordinator.shared.kick(reason: "insights cleanup")
    ContactsImportCoordinator.shared.kick(reason: "insights cleanup")
    
    // 3. Brief delay to allow coordinators to start
    try? await Task.sleep(for: .seconds(1))
    
    message = "Insights cleaned. Calendar & Contacts sync initiated."
}
```

**Flow:**
1. User clicks "Clean up corrupted insights" button
2. All `SamInsight` records deleted from database
3. Calendar import coordinator triggered → imports events → creates evidence → generates signals
4. Contacts import coordinator triggered → syncs people data
5. Evidence signals automatically generate new insights via `DebouncedInsightRunner`
6. User sees fresh, valid insights appear in Awareness/Inbox

---

### 2. Restore Developer Fixture

**Function:** `DeveloperFixtureButton.wipeAndReseed()`

```swift
@MainActor
private func wipeAndReseed() async {
    // 1. Delete all data in dependency order
    try modelContext.delete(model: SamInsight.self)
    try modelContext.delete(model: SamAnalysisArtifact.self)
    try modelContext.delete(model: SamNote.self)
    // ... (delete all models)
    try modelContext.save()
    
    // 2. Seed fixture data
    FixtureSeeder.seedIfNeeded(using: container)
    
    // 3. Trigger Calendar & Contacts sync
    CalendarImportCoordinator.shared.kick(reason: "fixture restore")
    ContactsImportCoordinator.shared.kick(reason: "fixture restore")
    
    // 4. Brief delay
    try? await Task.sleep(for: .seconds(1))
    
    message = "Developer fixture restored. Calendar & Contacts sync initiated."
}
```

**Flow:**
1. User clicks "Restore developer fixture" button
2. All data wiped from database (proper dependency order)
3. Fixture data seeded (Mary Smith, Evan Patel, Cynthia Lopez, etc.)
4. Calendar import triggered → supplements fixture with real calendar events
5. Contacts import triggered → links fixture people to real contacts
6. Combined fixture + real data creates rich testing environment

---

## Benefits

### User Experience
- **Immediate feedback:** Sync status shows in Import tab after cleanup
- **Automatic repopulation:** No need to manually trigger imports after cleanup
- **Seamless workflow:** One-click cleanup + sync instead of multi-step process

### Development Workflow
- **Faster testing:** Cleanup and repopulate in single action
- **Consistent state:** Always starts with fresh data after fixture restore
- **Real data testing:** Fixture combines with actual Calendar/Contacts data

### Technical Advantages
- **Idempotent operations:** Safe to click buttons multiple times
- **Throttled imports:** Coordinators respect 10-second throttle window
- **Non-blocking:** Async operations don't freeze UI

---

## Coordinator Integration

### CalendarImportCoordinator.kick()
```swift
CalendarImportCoordinator.shared.kick(reason: "insights cleanup")
```
- Bypasses throttle protection (explicit user action)
- Imports events from selected SAM calendar
- Creates `SamEvidenceItem` records with signals
- Triggers `DebouncedInsightRunner` to generate insights

### ContactsImportCoordinator.kick()
```swift
ContactsImportCoordinator.shared.kick(reason: "insights cleanup")
```
- Bypasses throttle protection
- Syncs contacts from selected SAM group
- Creates/updates `SamPerson` records
- Links people to contacts via `contactIdentifier`

### Reason Tracking
The `reason` parameter helps with debugging:
```
[CalendarImportCoordinator] Import triggered: insights cleanup
[ContactsImportCoordinator] Import triggered: fixture restore
```

---

## Timing & Sequencing

### Why the 1-Second Delay?
```swift
try? await Task.sleep(for: .seconds(1))
```

**Purpose:**
- Gives coordinators time to start background tasks
- Prevents race condition where message updates before sync starts
- User sees spinner/status indicator activate

**Alternative Considered:**
- Await coordinator completion (too slow for UI responsiveness)
- No delay (message updates before sync visible)
- **Selected:** 1-second compromise (feedback + responsiveness)

### Import Order
1. **Database cleanup completes** (blocking)
2. **Coordinators kicked** (non-blocking background tasks)
3. **Brief delay** (UI feedback window)
4. **Message updated** (user confirmation)
5. **Imports run in background** (async, throttled)
6. **Insights regenerate** (debounced, automatic)

---

## Testing Verification

### Manual Test Steps

**Test 1: Clean Up Insights**
1. Open Settings → Development tab
2. Click "Clean up corrupted insights"
3. ✅ Verify: Message shows "Insights cleaned. Calendar & Contacts sync initiated."
4. ✅ Verify: Import tab shows recent import activity
5. ✅ Verify: Awareness tab repopulates with insights after ~5 seconds

**Test 2: Restore Fixture**
1. Open Settings → Development tab
2. Click "Restore developer fixture"
3. ✅ Verify: Message shows "Developer fixture restored. Calendar & Contacts sync initiated."
4. ✅ Verify: People list shows fixture people (Mary, Evan, Cynthia)
5. ✅ Verify: Inbox shows evidence from both fixture + calendar events

**Test 3: Permission Edge Cases**
1. Revoke Calendar permission (System Settings)
2. Click cleanup button
3. ✅ Verify: No crash, gracefully skips calendar import
4. ✅ Verify: Contacts still sync if permission granted

---

## Edge Cases Handled

### No Permissions
- Coordinators check authorization status before importing
- Silent no-op if permissions denied
- No error shown to user (expected behavior)

### No Calendar/Group Selected
- Coordinators check for selected calendar ID / group identifier
- Silent no-op if nothing configured
- User can select calendar later and manually trigger import

### Empty Calendar/Contacts
- Import completes successfully with zero items
- No insights generated (expected)
- No error state

### Concurrent Operations
- Multiple clicks on cleanup button are safe
- Throttle protection prevents duplicate imports
- Last kick wins (resets throttle timer)

---

## Future Enhancements

### Potential Improvements
1. **Progress Tracking**
   - Show import progress in status message
   - "Importing calendar... 15 events processed"
   - "Syncing contacts... 8 people updated"

2. **Completion Callback**
   - Wait for coordinators to fully complete
   - Update message when all imports finish
   - Show count of items imported

3. **Batch Operations**
   - Add "Full Refresh" button that:
     - Cleans all data
     - Imports calendar
     - Syncs contacts
     - Regenerates all insights
     - Shows comprehensive progress

4. **Selective Sync**
   - Checkboxes to choose what to sync
   - "Sync calendar only"
   - "Sync contacts only"
   - "Sync both" (current behavior)

5. **Error Handling**
   - Catch import errors and display in UI
   - Offer retry button if sync fails
   - Log to DevLogger for debugging

---

## Related Files

### Modified
- `BackupTab.swift` - Added sync triggers to cleanup functions

### Related Coordinators
- `CalendarImportCoordinator.swift` - Handles calendar event import
- `ContactsImportCoordinator.swift` - Handles contact synchronization
- `DebouncedInsightRunner.swift` - Regenerates insights from evidence

### Related Models
- `SamEvidenceItem` - Created by calendar import
- `SamPerson` - Updated by contacts sync
- `SamInsight` - Regenerated from evidence signals

---

## Design Rationale

### Why Automatic vs. Manual?
- **Automatic:** Better UX, one-click workflow, less cognitive load
- **Manual:** More control, explicit confirmation, visible in logs
- **Decision:** Automatic with clear user feedback (message + visible import activity)

### Why Both Coordinators?
- **Calendar:** Provides evidence → signals → insights
- **Contacts:** Provides people → links evidence → enriches insights
- **Together:** Complete picture of user's CRM data

### Why Not Wait for Completion?
- **Responsiveness:** Button feels instant, user can continue working
- **Background work:** Imports happen asynchronously without blocking
- **Feedback:** Import tab and badge counts show progress

---

## Summary

✅ **Cleanup operations now trigger data sync automatically**  
✅ **Calendar events imported after database cleanup**  
✅ **Contacts synced to refresh people data**  
✅ **Insights regenerate automatically from fresh evidence**  
✅ **User-friendly feedback messages**  
✅ **Non-blocking background operations**

**Result:** Database cleanup is now a complete workflow that leaves the app in a fully-functional state with fresh data and insights.
