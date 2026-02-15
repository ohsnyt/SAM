# Plan: Email Integration — Mail.app via AppleScript

## Context

SAM ingests evidence from Calendar and Contacts by observing Apple's native apps. Haiku built email integration scaffolding using direct IMAP, but this contradicts SAM's core philosophy: "observe Apple apps, don't replace them." Mail.app has a comprehensive AppleScript dictionary that allows reading accounts, mailboxes, and messages — the same observe-and-enrich pattern used for Contacts and Calendar.

**Why Mail.app, not IMAP:**
- Zero credential friction (Mail.app already has the user's accounts)
- Consistent with Contacts/Calendar pattern (observe Apple's app)
- No SwiftNIO dependency or MIME parsing needed
- Tested on this machine: 30,550 messages accessible, bulk fetch ~1,170 msg/s

**Sandbox constraint:** SAM is sandboxed. Mail.sdef only exposes `com.apple.mail.compose` for sandboxed apps — reading messages has no access group. Fix: add `com.apple.security.temporary-exception.apple-events` targeting `com.apple.mail`. This is fine since SAM is not an App Store app.

## What Changes

### Files to REWRITE (1)

**`Services/MailService.swift`** — Replace IMAP stubs with NSAppleScript bridge

### Files to MODIFY (4)

| File | Change |
|------|--------|
| `Coordinators/MailImportCoordinator.swift` | Remove IMAP config (host/port/username), add account selection |
| `Views/Settings/MailSettingsView.swift` | Replace credential fields with Mail.app account picker |
| `Services/EmailAnalysisService.swift` | Fix EntityKind bug, fix Swift 6 Codable warning |
| `SAM_crm.entitlements` | Add Apple Events temporary exception for Mail.app |
| `Info.plist` | Add `NSAppleEventsUsageDescription` |

### Files to DELETE (1)

**`Utilities/KeychainHelper.swift`** — No credentials to store (Mail.app handles auth)

### Files to KEEP AS-IS (5)

| File | Why |
|------|-----|
| `Models/DTOs/EmailDTO.swift` | All fields map directly to AppleScript properties |
| `Models/DTOs/EmailAnalysisDTO.swift` | Source-agnostic LLM results |
| `Utilities/MailFilterRule.swift` | Filtering logic is source-independent |
| `Repositories/EvidenceRepository.swift` | `bulkUpsertEmails()` and `pruneMailOrphans()` operate on DTOs |
| `App/SAMApp.swift` | Mail trigger already wired correctly |

---

## Step-by-Step Implementation

### Step 1: Entitlements & Info.plist

**`SAM/SAM_crm.entitlements`** — Add Apple Events exception:
```xml
<key>com.apple.security.temporary-exception.apple-events</key>
<array>
    <string>com.apple.mail</string>
</array>
```

**`SAM/Info.plist`** — Add usage description:
```xml
<key>NSAppleEventsUsageDescription</key>
<string>SAM needs to read your Mail to track email interactions with your clients. SAM only stores summaries — never raw email content.</string>
```

### Step 2: Rewrite MailService.swift

Replace the entire file. New actor uses `NSAppleScript` to talk to Mail.app.

**Key design decisions:**
- Use `NSAppleScript(source:).executeAndReturnError()` (fastest, 0.6s per operation)
- Bulk property access (`subject of every message whose ...`) — 50x faster than looping
- Filter by date on the AppleScript side (`whose date received > cutoffDate`), then apply MailFilterRules in Swift
- Return `EmailDTO` array exactly as before — downstream code unchanged

**Methods:**

```swift
actor MailService {
    static let shared = MailService()

    /// Check if Mail.app is available and we have automation permission.
    /// Returns nil on success, error message on failure.
    func checkAccess() async -> String?

    /// Fetch available Mail.app accounts.
    func fetchAccounts() async -> [MailAccountDTO]

    /// Fetch recent emails from selected accounts' inboxes.
    func fetchEmails(
        accountIDs: [String],
        since: Date,
        filterRules: [MailFilterRule]
    ) async throws -> [EmailDTO]
}

/// Lightweight account info for Settings UI picker.
struct MailAccountDTO: Sendable, Identifiable {
    let id: String        // Mail.app account ID
    let name: String      // e.g. "iCloud", "Gmail - work@example.com"
    let emailAddresses: [String]
}
```

**AppleScript strategy (performance-optimized):**

1. **Metadata sweep** — Bulk fetch `{id, message id, subject, sender, date received}` of messages matching date filter. This is fast (~2s for thousands).
2. **Filter in Swift** — Apply `MailFilterRule` matches against sender emails.
3. **Body fetch** — For matching messages only, fetch `content` individually (~0.7s each). Limit to first N messages per import to bound runtime.
4. **Construct EmailDTOs** — Map AppleScript results to DTOs.

**AppleScript template for metadata sweep:**
```applescript
tell application "Mail"
    set cutoff to (current date) - (DAYS * days)
    set msgs to every message of inbox whose date received > cutoff
    set msgData to {}
    repeat with m in msgs
        set end of msgData to {id of m, message id of m, subject of m, sender of m, date received of m}
    end repeat
    return msgData
end tell
```

Note: For better performance, use bulk property access:
```applescript
tell application "Mail"
    set cutoff to (current date) - (30 * days)
    set mbx to inbox
    set filteredMsgs to (every message of mbx whose date received > cutoff)
    set msgIDs to id of filteredMsgs
    set msgMessageIDs to message id of filteredMsgs
    set msgSubjects to subject of filteredMsgs
    set msgSenders to sender of filteredMsgs
    set msgDates to date received of filteredMsgs
end tell
```
This returns parallel arrays — much faster than per-message access.

**For individual message body + recipients:**
```applescript
tell application "Mail"
    set m to first message of inbox whose id is MSG_ID
    set msgContent to content of m
    set msgRecipients to address of every to recipient of m
    set msgCC to address of every cc recipient of m
    set msgRead to read status of m
end tell
```

**Parsing NSAppleEventDescriptor:** The return values from `NSAppleScript.executeAndReturnError()` come as `NSAppleEventDescriptor`. Need a helper to convert descriptors to Swift arrays/strings. This is straightforward — `descriptor.numberOfItems`, `descriptor.atIndex()`, `descriptor.stringValue`.

### Step 3: Modify MailImportCoordinator.swift

**Remove:**
- `imapHost`, `imapPort`, `imapUsername` properties
- `saveCredentials()`, `removeCredentials()`, `testConnection()`
- `isConfigured` check based on IMAP host/credentials

**Add:**
```swift
@ObservationIgnored
var selectedAccountIDs: [String] {
    get { UserDefaults.standard.stringArray(forKey: "mailSelectedAccountIDs") ?? [] }
    set { UserDefaults.standard.set(newValue, forKey: "mailSelectedAccountIDs") }
}

/// Available Mail.app accounts (loaded from service, not persisted)
var availableAccounts: [MailAccountDTO] = []

var isConfigured: Bool {
    !selectedAccountIDs.isEmpty
}
```

**Update `performImport()`:**
- Replace `MailService.IMAPConfig` construction with `mailService.fetchEmails(accountIDs: selectedAccountIDs, ...)`
- Remove Keychain password lookup
- Keep analysis → upsert → insights → prune pipeline unchanged

**Fix pruning safety:** Only prune if fetch returned at least 1 email (prevents empty-fetch from deleting everything):
```swift
if !emails.isEmpty {
    let validUIDs = Set(emails.map { $0.sourceUID })
    try evidenceRepository.pruneMailOrphans(validSourceUIDs: validUIDs)
}
```

### Step 4: Modify MailSettingsView.swift

**Replace** the IMAP Account section (host/port/username/password/test) with:

```swift
Section {
    if coordinator.availableAccounts.isEmpty {
        Text("No Mail accounts found. Configure accounts in Mail.app.")
            .foregroundStyle(.secondary)
    } else {
        ForEach(coordinator.availableAccounts) { account in
            Toggle(isOn: accountBinding(for: account.id)) {
                VStack(alignment: .leading) {
                    Text(account.name)
                    Text(account.emailAddresses.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
} header: {
    Text("Mail.app Accounts")
} footer: {
    Text("Select which Mail.app accounts to monitor. SAM reads email metadata and generates summaries — raw message bodies are never stored.")
}
```

**Keep:** Import Settings section, Sender Filters section, Status section (remove "Remove Account" danger zone).

**Add** `loadAccounts()` on appear:
```swift
.task {
    coordinator.availableAccounts = await MailService.shared.fetchAccounts()
}
```

### Step 5: Fix EmailAnalysisService.swift bugs

**Bug 1 — EntityKind rawValue mapping** (line 109):
```swift
// BEFORE (broken):
kind: EmailEntityDTO.EntityKind(rawValue: e.kind.replacingOccurrences(of: "_", with: "")) ?? .person

// AFTER (explicit mapping):
kind: Self.mapEntityKind(e.kind)

// New helper:
private static func mapEntityKind(_ raw: String) -> EmailEntityDTO.EntityKind {
    switch raw {
    case "person": .person
    case "organization": .organization
    case "product": .product
    case "financial_instrument": .financialInstrument
    default: .person
    }
}
```

**Bug 2 — Swift 6 Codable isolation warning** (line 98):

The private `LLMEmailResponse` struct inherits `@MainActor` from the default isolation setting. Mark it `nonisolated` to fix:
```swift
// Add nonisolated(unsafe) or use @preconcurrency
nonisolated private struct LLMEmailResponse: Codable { ... }
nonisolated private struct LLMEntity: Codable { ... }
nonisolated private struct LLMTemporalEvent: Codable { ... }
```

### Step 6: Delete KeychainHelper.swift

No longer needed — Mail.app manages its own credentials. Remove the file and remove it from the Xcode project.

### Step 7: Update PermissionsManager (if it exists) or SettingsView

Add Mail automation permission status display to the Permissions tab in SettingsView. This mirrors how Contacts and Calendar permissions are shown. The check uses `AEDeterminePermissionToAutomateTarget` or simply attempts a lightweight AppleScript and checks for error -1743 (not authorized).

---

## File Inventory

| # | File | Action | Lines Changed (est.) |
|---|------|--------|---------------------|
| 1 | `SAM_crm.entitlements` | Modify | +4 |
| 2 | `Info.plist` | Modify | +2 |
| 3 | `Services/MailService.swift` | Rewrite | ~200 |
| 4 | `Coordinators/MailImportCoordinator.swift` | Modify | ~80 changed |
| 5 | `Views/Settings/MailSettingsView.swift` | Modify | ~80 changed |
| 6 | `Services/EmailAnalysisService.swift` | Modify | ~15 changed |
| 7 | `Utilities/KeychainHelper.swift` | Delete | -59 |

**No changes to:** EmailDTO, EmailAnalysisDTO, MailFilterRule, EvidenceRepository, SAMApp.

---

## Verification

1. **Build**: `cd /Users/david/Swift/SAM/SAM && xcodebuild build -scheme SAM -destination 'platform=macOS'`
2. **Tests**: All 67 existing tests should still pass
3. **Permission prompt**: First launch after changes should show "SAM wants to control Mail.app" dialog
4. **Settings → Mail tab**: Should list Mail.app accounts with toggle checkboxes
5. **Import Now**: Should fetch emails from selected accounts, show count in status
6. **Inbox**: Email evidence should appear with `.mail` source badge, summaries (not raw bodies)
7. **Filter rules**: Adding a sender filter should limit which emails are imported on next run
