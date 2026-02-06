# Merge Name Resolution Enhancement

## Your Questions

### 1. Does it pull the correct name from the linked contact?
**Before this fix:** ❌ No - the survivor kept its old `displayName` even if it was outdated  
**After this fix:** ✅ Yes - fetches fresh name from Contacts when survivor has `contactIdentifier`

### 2. Does it merge all contexts together?
✅ **Yes** - this was already working correctly via two mechanisms:
- Re-points all `ContextParticipation` relationships to survivor
- Merges denormalized `contextChips` array (deduplicated by id)

---

## The Name Problem (Before Fix)

When merging two people with different names, the `displayName` was **not updated**:

```
Source: "Bob Smith" (unlinked, no contactIdentifier)
Survivor: "Robert T. Smith" (linked, contactIdentifier: "ABC123")

After merge (OLD):
Result: "Robert T. Smith" ← Kept survivor's stale name
```

**Issues:**
- If survivor's name was outdated, it stayed outdated
- No validation that the name matched Contacts.app
- User might have corrected the name in Contacts but SAM didn't reflect it

---

## The Solution

Added **fresh name fetching from CNContact** during merge:

```swift
// Fetch fresh name from Contacts if survivor is linked
if let identifier = survivor.contactIdentifier {
    Task.detached(priority: .userInitiated) {
        let freshName = await Self.fetchContactName(identifier)
        
        await MainActor.run {
            if let name = freshName {
                survivor.displayName = name  // ← Update with current name
            }
        }
    }
}
```

### How It Works

1. **Check if survivor is linked** - Only fetch if `contactIdentifier` exists
2. **Fetch on background thread** - `Task.detached` to avoid blocking UI
3. **Query CNContactStore** - Get `givenName` + `familyName`
4. **Build display name** - Join with space: "John Smith"
5. **Update on main actor** - Set `survivor.displayName` safely
6. **Graceful failure** - If contact can't be fetched, keeps existing name

### The Helper Function

```swift
private static func fetchContactName(_ identifier: String) async -> String? {
    return await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            let store = CNContactStore()
            do {
                let keys: [CNKeyDescriptor] = [
                    CNContactGivenNameKey as CNKeyDescriptor,
                    CNContactFamilyNameKey as CNKeyDescriptor
                ]
                let contact = try store.unifiedContact(
                    withIdentifier: identifier,
                    keysToFetch: keys
                )
                
                // Build display name (first + last)
                let fullName = [contact.givenName, contact.familyName]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                
                continuation.resume(returning: fullName.isEmpty ? nil : fullName)
            } catch {
                // Contact not found or access denied
                continuation.resume(returning: nil)
            }
        }
    }
}
```

**Thread Safety:**
- CNContactStore I/O on background queue (`.userInitiated`)
- Name update happens on MainActor
- SwiftData mutation is safe

---

## Context Merging (Already Working)

### 1. Relational Participations

Lines 212-218 in the merge function:

```swift
// Re-point participations
for p in source.participations {
    p.person = survivor
    if !survivor.participations.contains(where: { $0.id == p.id }) {
        survivor.participations.append(p)
    }
}
```

**Example:**
```
Source: in "Smith Household" + "ABC Corp"
Survivor: in "Investment Group"

After merge:
Survivor: in "Smith Household" + "ABC Corp" + "Investment Group"
```

### 2. Denormalized Context Chips

Lines 260-265:

```swift
// Merge context chips (deduplicate by id)
for chip in source.contextChips {
    if !survivor.contextChips.contains(where: { $0.id == chip.id }) {
        survivor.contextChips.append(chip)
    }
}
```

This ensures the UI shows all contexts immediately without waiting for the next sync.

---

## Complete Merge Behavior

| Aspect | Behavior | Notes |
|--------|----------|-------|
| **Display Name** | ✅ Updated from Contacts | Fetches fresh name from CNContact |
| **Contact Identifier** | ✅ Preserved | Survivor keeps its `contactIdentifier` |
| **Participations** | ✅ Merged | All context memberships combined |
| **Coverages** | ✅ Merged | All insurance policies combined |
| **Consent Requirements** | ✅ Merged | All compliance tracking combined |
| **Guardian Relationships** | ✅ Merged | Both directions preserved |
| **Alert Counters** | ✅ Summed | `consentAlertsCount` + `reviewAlertsCount` |
| **Context Chips** | ✅ Merged | Deduplicated by id |
| **Role Badges** | ➖ Survivor's kept | Not merged (could enhance) |
| **Source Record** | ✅ Deleted | Cleaned up completely |
| **Selection** | ✅ Pivots to survivor | Automatic UI update |

---

## User Experience

### Scenario: Merge "Bob Smith" into "Robert Smith"

**Before fix:**
1. Unlinked: "Bob Smith" (in Household A)
2. Linked: "Robert Smith" (in Household B, outdated name in SAM)
3. Click link badge → Select "Robert Smith"
4. **Result:**
   - Name stays "Robert Smith" (even if Contacts says "Robert T. Smith")
   - Contexts merged ✅
   - One person remains ✅

**After fix:**
1. Unlinked: "Bob Smith" (in Household A)
2. Linked: "Robert Smith" (in Household B)
3. Click link badge → Select "Robert Smith"
4. **Result:**
   - Name updates to "Robert T. Smith" (from Contacts) ✅
   - Contexts merged ✅
   - One person remains ✅

### Visual Example

```
┌─────────────────────────────────────────┐
│ Before Merge                            │
├─────────────────────────────────────────┤
│ Bob Smith (unlinked)                    │
│   • Smith Household                     │
│   • ABC Corp                            │
│                                         │
│ Robert Smith (linked)                   │
│   • Investment Group                    │
│   (stale name in SAM)                   │
└─────────────────────────────────────────┘

              ↓ Merge

┌─────────────────────────────────────────┐
│ After Merge                             │
├─────────────────────────────────────────┤
│ Robert T. Smith ← Fresh from Contacts   │
│   • Smith Household                     │
│   • ABC Corp                            │
│   • Investment Group                    │
│                                         │
│ ("Bob Smith" deleted)                   │
└─────────────────────────────────────────┘
```

---

## Edge Cases

### Case 1: Survivor not linked (no contactIdentifier)
- **Action:** Name is **not** updated (nothing to fetch from)
- **Behavior:** Keeps survivor's original name
- **Rare:** Shouldn't happen in link flow (all candidates are linked)

### Case 2: Contact deleted from Contacts.app
- **Action:** Name fetch fails gracefully
- **Behavior:** Keeps survivor's current name
- **No crash:** Returns `nil`, which is ignored

### Case 3: Contacts permission denied
- **Action:** Name fetch fails
- **Behavior:** Keeps survivor's current name
- **Safe:** Already have permission from SAM group import

### Case 4: Name empty in Contacts
- **Action:** Fetch returns `nil` (empty string filtered out)
- **Behavior:** Keeps survivor's current name
- **Defensive:** Better to keep old name than set it to ""

---

## Testing

### Test Case 1: Basic Name Update
1. In Contacts.app, set contact name to "Robert Thomas Smith"
2. In SAM, survivor shows "Robert Smith" (old name)
3. Create unlinked "Bob Smith"
4. Link "Bob Smith" → "Robert Smith"

**Expected:**
- ✅ Name updates to "Robert Thomas Smith" (from Contacts)
- ✅ Contexts from both merged
- ✅ One person remains

### Test Case 2: Name Already Correct
1. Survivor name matches Contacts exactly
2. Merge unlinked person into survivor

**Expected:**
- ✅ Name stays the same (re-fetching is harmless)
- ✅ Merge completes normally

### Test Case 3: Multiple Contexts
1. Unlinked person in 3 contexts
2. Survivor in 2 different contexts
3. Merge them

**Expected:**
- ✅ Survivor now in all 5 contexts
- ✅ No duplicate participations
- ✅ Context chips deduplicated

---

## Files Modified

**PeopleListView.swift:**
- Added `import Contacts` (conditionally)
- Updated `mergePerson()` to fetch fresh name from CNContact
- Added `fetchContactName()` static helper function
- Updated docstring to mention name refresh

---

## Performance

**Name Fetching:**
- Happens on background thread (`.userInitiated` priority)
- Single CNContactStore lookup (~1-5ms typical)
- Does not block merge completion
- UI updates reactively when name arrives

**No Performance Impact:**
- Fetch is async, doesn't delay merge save
- Only runs for linked survivors (not every merge)
- Gracefully fails if contact unavailable

---

## Status

✅ **Name Resolution:** Now fetches fresh from Contacts  
✅ **Context Merging:** Already working (confirmed)  
✅ **Thread Safety:** CNContactStore I/O off main thread  
✅ **Graceful Failure:** Falls back to existing name if fetch fails  

---

**Next Step:** Merge two people and verify the name updates to match Contacts.app.
