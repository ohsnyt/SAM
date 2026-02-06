# Link Contact → Merge Fix

## Problem

When linking an unlinked person to an existing linked contact in the picker, two `SamPerson` records were left pointing to the same `contactIdentifier`. This created duplicates in the UI.

**Example:**
- Unlinked person: "Bob Smith" (no `contactIdentifier`)
- Click link badge → Pick "Robert Smith" (has `contactIdentifier: "ABC123"`)
- **Expected:** One person ("Robert Smith")
- **Actual:** Two people both with `contactIdentifier: "ABC123"`

## Root Cause

The `linkToContact()` function in `LinkContactSheet` was calling `onLinked(identifier)`, which only **sets the contactIdentifier** on the current person. It didn't detect that the selected contact already represents a different `SamPerson` record.

```swift
// Old implementation
private func linkToContact(_ candidate: PersonDuplicateCandidate) {
    guard let identifier = candidate.contactIdentifier else { return }
    
    if candidate.id != person.id {
        onLinked(identifier)  // ← Just sets contactIdentifier
    }
    
    dismiss()
}
```

This made the unlinked person "linked" but didn't remove it or consolidate relationships.

## Solution

Detect when the candidate is a **different person** and trigger a **merge** instead of just adopting the identifier.

```swift
// New implementation
private func linkToContact(_ candidate: PersonDuplicateCandidate) {
    guard let identifier = candidate.contactIdentifier else { return }
    
    // If the candidate is a different person (not the one we're linking),
    // this is a merge scenario - the candidate is an existing linked person
    // and we want to merge the current unlinked person into it.
    if candidate.id != person.id {
        onMerge(candidate.id)  // ← Merge instead of link
    } else {
        // This shouldn't happen (we filter out self), but just adopt the identifier
        onLinked(identifier)
    }
    
    dismiss()
}
```

## What Happens on Merge

The existing `mergePerson()` function in `PeopleListView` already handles all the consolidation:

1. **Re-point participations** — Move all `ContextParticipation` records from source to survivor
2. **Re-point coverages** — Move all insurance coverages
3. **Re-point consent requirements** — Move all consent tracking
4. **Re-point responsibilities** — Move guardian/dependent relationships in both directions
5. **Adopt contactIdentifier** — If survivor lacks one, adopt from source (defensive)
6. **Merge alert counters** — Add source counts to survivor
7. **Merge context chips** — Deduplicate by id
8. **Delete source** — Remove the unlinked person completely
9. **Pivot selection** — Automatically select the survivor

### Merge Logic (from PeopleListView)

```swift
private func mergePerson(_ sourceID: UUID, into survivingID: UUID) {
    guard let source   = people.first(where: { $0.id == sourceID }),
          let survivor = people.first(where: { $0.id == survivingID }) else { return }

    // Re-point participations
    for p in source.participations {
        p.person = survivor
        if !survivor.participations.contains(where: { $0.id == p.id }) {
            survivor.participations.append(p)
        }
    }

    // Re-point coverages, consent, responsibilities...
    // (full implementation in PeopleListView.swift)

    // Delete the source
    modelContext.delete(source)

    try? modelContext.save()

    // Pivot selection to survivor
    if selectedPersonID == sourceID {
        selectedPersonID = survivingID
    }
}
```

## User Experience

### Before Fix
1. Click unlinked badge on "Bob Smith"
2. Pick "Robert Smith" from list
3. **Result:** Two people in the list:
   - "Bob Smith" (linked)
   - "Robert Smith" (linked)
   - Both point to same contact ❌

### After Fix
1. Click unlinked badge on "Bob Smith"
2. Pick "Robert Smith" from list
3. **Result:** One person in the list:
   - "Robert Smith" (linked)
   - All relationships from "Bob Smith" moved over
   - Selection auto-pivots to "Robert Smith" ✅

## Edge Cases Handled

### Case 1: Survivor already has contactIdentifier
- **Action:** Merge succeeds, survivor keeps its identifier
- **Source identifier:** Discarded (not needed)

### Case 2: Survivor lacks contactIdentifier (shouldn't happen in picker)
- **Action:** Merge succeeds, survivor adopts source's identifier
- **Defensive:** This shouldn't occur since we filter to `contactIdentifier != nil`

### Case 3: Source has relationships (participations, coverages, etc.)
- **Action:** All relationships re-pointed to survivor
- **No data loss:** Everything preserved

### Case 4: Both have same context chips
- **Action:** Deduplicated by id
- **No duplicates:** Context chips merged cleanly

## Testing

### Test Case 1: Merge Unlinked Person into Linked Person
1. Create unlinked person "Bob Smith"
2. Ensure linked person "Robert Smith" exists
3. Click unlinked badge on "Bob Smith"
4. Select "Robert Smith" from picker

**Expected:**
- ✅ "Bob Smith" disappears from list
- ✅ "Robert Smith" remains (with all relationships)
- ✅ Selection pivots to "Robert Smith"
- ✅ Only one person in database with that `contactIdentifier`

### Test Case 2: Merge with Relationships
1. Create unlinked person "Jane Doe"
2. Add "Jane Doe" to a Household context
3. Ensure linked person "Jane Doe" (different record) exists
4. Click unlinked badge → Select linked "Jane Doe"

**Expected:**
- ✅ Unlinked "Jane Doe" disappears
- ✅ Linked "Jane Doe" now has the Household participation
- ✅ Household context shows one "Jane Doe" participant

### Test Case 3: Suggested Match Merge
1. Create unlinked "Bob Smith"
2. Linked "Robert Smith" exists (high match score)
3. Click unlinked badge → "Robert Smith" appears in SUGGESTED MATCHES
4. Click "Robert Smith"

**Expected:**
- ✅ Merge happens (not just contactIdentifier adoption)
- ✅ One person remains

## Files Modified

**LinkContactSheet.swift**
- Changed `linkToContact()` to call `onMerge(candidate.id)` instead of `onLinked(identifier)`
- Now correctly triggers merge flow for all picker selections

**PeopleListView.swift**
- No changes needed
- Existing `mergePerson()` already handles all the logic

## Related Flows

### When to Use `onLinked` vs `onMerge`

| Scenario | Callback | Behavior |
|----------|----------|----------|
| **Pick existing linked person** | `onMerge(survivorID)` | Merge source into survivor, delete source |
| **Create new contact** | `onLinked(identifier)` | Adopt new identifier, keep person |
| **Manual identifier assignment** | `onLinked(identifier)` | Just set the field |

In the picker flow, **all selections are merges** because every candidate is an existing `SamPerson` with its own UUID.

## Benefits

✅ **No duplicates** - Only one person per `contactIdentifier`  
✅ **Relationship consolidation** - All data moved to survivor  
✅ **Clean UI** - Selection pivots automatically  
✅ **Data integrity** - No orphaned records  
✅ **Expected behavior** - "Link to this contact" naturally means "this IS that contact"

## Status

✅ **Fix Applied**  
🧪 **Ready for Testing**  
📝 **One line change, big UX improvement**

---

**Next Step:** Link an unlinked person to an existing contact and verify they merge into one.
