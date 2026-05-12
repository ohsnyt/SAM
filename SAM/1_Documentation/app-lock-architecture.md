# App Lock Architecture

SAM is **always-locked-on-launch** and re-locks on idle / OS lock / sleep. The brief overview is in `context.md` §9; this doc has the implementation details.

## Components

| Component | Role |
|-----------|------|
| `AppLockService` | Lock state, idle timer, biometric prompt orchestration |
| `LockOverlayCoordinator` | Per-window child overlay windows (glass-block) covering all visible windows |
| `LockOverlayWindow` | The actual child window — covers a parent window with a frosted/glass blocker |
| `ModalCoordinator` | Dismisses sheets/alerts/file panels on lock (preserves no-secret-state UI) |
| `DraftStore` | In-memory autosave for in-progress edit forms — restores text on unlock |

## Lock Trigger Sources

Lock fires on **any** of:

- App launch (always)
- Idle timer expiry (foreground inactivity while user sits on SAM without interacting)
- System lock — Distributed notifications `screenIsLocked`, `com.apple.screensaver.didstart`
- Sleep — `NSWorkspace.willSleepNotification`

## Unlock Trigger Sources

Unlock biometric prompt auto-fires (no click required) on **any** of:

- `screenIsUnlocked` distributed notification
- `com.apple.screensaver.didstop` distributed notification
- `NSWorkspace.didWakeNotification`
- `LockOverlayWindow.didBecomeKey` (failsafe when the user clicks the overlay)

Uses `LocalAuthentication` framework with `LAPolicy.deviceOwnerAuthentication` (Touch ID + system password fallback). **There is no opt-out setting** — lock is mandatory.

## On-Lock Behavior

1. Auxiliary windows are `orderOut(nil)`'d (state preserved, not destroyed)
2. `LockOverlayCoordinator` adds a `LockOverlayWindow` as a child of every visible parent window
3. `ModalCoordinator.dismissAllOnLock()` removes sheets/alerts/file panels
4. Forms wired with `DraftStore` autosave their unsaved text in memory

## On-Unlock Behavior

1. Biometric prompt fires
2. On success, overlays are removed, auxiliary windows `orderFront(nil)`'d
3. `ModalCoordinator` restores sheets that were marked `.restoreOnUnlock`
4. Forms wired with `DraftStore` repopulate their unsaved text

Passphrase sheets are dismiss-only on lock (security boundary — never restore).

## Forms Wired with DraftStore

`NoteEditorView`, `ComposeWindowView`, `ContentDraftSheet`, `EventFormView`, `GoalEntryForm`, `ProductionEntryForm`, `ManualTaskSheet`, `CorrectionSheetView`.

## Other Security Primitives

- **Backup encryption is mandatory** — All exports require a user-supplied passphrase. AES-256-GCM with HKDF-SHA256 key derivation. `SAMENC1` header for format detection.
- **Clipboard auto-clear** — `ClipboardSecurity.copy(_:clearAfter:)` clears sensitive data after 60s. Non-sensitive uses `copyPersistent(_:)`.
- **Log privacy** — All PII (names, emails, phones, social URLs, contact IDs) uses `privacy: .private` in os.log calls.
- **Keychain storage** — `KeychainService` actor wraps Security framework (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`).
- **Database encryption** — Not used separately. FileVault + app sandbox handle isolation. `FileProtectionType.complete` causes SQLite I/O errors on macOS and is not applied.
