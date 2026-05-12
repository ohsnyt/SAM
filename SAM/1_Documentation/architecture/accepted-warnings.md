# Accepted Build / Runtime Warnings

Warnings SAM intentionally lives with, with the reasoning. Revisit only if Instruments shows measurable impact.

## Thread Performance Checker — Hang Risk on CNContactStore

The Thread Performance Checker reports priority inversion ("Hang Risk") on two lines where `CNContactStore` synchronously calls Apple's `contactsd` daemon via XPC:

- `SAM/Services/ContactsService.swift` — `store.unifiedContacts(matching:keysToFetch:)` (around line 255)
- `SAM/Services/ContactsService.swift` — `store.unifiedMeContactWithKeys(toFetch:)` (around line 297)

These inversions originate inside Apple's framework (the daemon responds on an internal Background-QoS thread), not in our code. Our `ContactsService` actor already uses a `DispatchSerialQueue` pinned to `.userInitiated` QoS as a custom executor, so our side is correct.

The warnings are runtime diagnostics with no per-line suppression API. They are practically minor — macOS priority inheritance typically boosts the blocked thread within milliseconds. Accepted as known, low-impact noise.

**Revisit trigger**: Only if Instruments shows measurable hangs on these code paths.
