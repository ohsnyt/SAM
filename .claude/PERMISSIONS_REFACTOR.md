# Centralized Permissions Architecture

## Problem Statement

Previously, authorization checks and permission requests were scattered across multiple files:

- **ContactsImportCoordinator**: Checked and requested Contacts access
- **CalendarImportCoordinator**: Checked and requested Calendar access  
- **SamSettingsView**: Checked and requested both
- **ContactsSyncManager**: Checked Contacts access multiple times

This led to:
- ❌ Multiple permission dialogs appearing unexpectedly
- ❌ Inconsistent permission state across the app
- ❌ No single source of truth for authorization status
- ❌ Background tasks potentially triggering permission dialogs

## Solution: PermissionsManager

A centralized `@MainActor` singleton that:

### ✅ Single Source of Truth
- Maintains **one shared EKEventStore** instance
- Maintains **one shared CNContactStore** instance
- Publishes authorization status changes via `@Published` properties
- Posts `Notification.permissionsDidChange` when status changes

### ✅ Clear Separation of Concerns

**Checking permissions** (no dialogs):
```swift
// These properties NEVER trigger permission dialogs
permissions.hasCalendarAccess      // .fullAccess or .writeOnly
permissions.hasFullCalendarAccess  // .fullAccess only
permissions.hasContactsAccess      // .authorized
permissions.hasAllRequiredPermissions  // Calendar + Contacts
```

**Requesting permissions** (UI-initiated only):
```swift
// ONLY call from Settings or onboarding UI
await permissions.requestCalendarAccess()
await permissions.requestContactsAccess()
await permissions.requestAllPermissions()
```

### ✅ Automatic State Synchronization

The manager observes system notifications:
- `EKEventStoreChanged` → refreshes calendar status
- `CNContactStoreDidChange` → refreshes contacts status

When status changes:
1. Updates `@Published` properties (triggers UI updates)
2. Posts `.permissionsDidChange` notification (coordinators can listen)

## Migration Summary

### ContactsImportCoordinator
**Before:**
```swift
static let contactStore = CNContactStore()

let auth = CNContactStore.authorizationStatus(for: .contacts)
guard auth == .authorized else { return }

let granted = try await withCheckedThrowingContinuation { ... }
guard granted else { return }
```

**After:**
```swift
private let permissions = PermissionsManager.shared

guard permissions.hasContactsAccess else { return }
let contactStore = permissions.contactStore
```

### CalendarImportCoordinator
**Before:**
```swift
static let eventStore = EKEventStore()

let status = EKEventStore.authorizationStatus(for: .event)
guard status == .fullAccess else { return }

try await Self.eventStore.requestFullAccessToEvents()
```

**After:**
```swift
private let permissions = PermissionsManager.shared

guard permissions.hasFullCalendarAccess else { return }
let eventStore = permissions.eventStore

try await eventStore.requestFullAccessToEvents()
```

### SamSettingsView
**Before:**
```swift
@State private var calendarAuthStatus: EKAuthorizationStatus
@State private var contactsAuthStatus: CNAuthorizationStatus
private static let contactStore = CNContactStore()

private func refreshAuthStatuses() {
    calendarAuthStatus = EKEventStore.authorizationStatus(for: .event)
    contactsAuthStatus = CNContactStore.authorizationStatus(for: .contacts)
}

private func requestCalendarAccessAndReload() async {
    _ = try await CalendarImportCoordinator.eventStore.requestFullAccessToEvents()
    // ... manual status refresh ...
}
```

**After:**
```swift
@ObservedObject private var permissions = PermissionsManager.shared

// Status is automatically updated via @Published properties

private func requestCalendarAccessAndReload() async {
    let granted = await permissions.requestCalendarAccess()
    // Status automatically refreshed
    if granted {
        reloadCalendars()
        CalendarImportCoordinator.shared.kick(reason: "calendar permission granted")
    }
}
```

### ContactsSyncManager
**Before:**
```swift
let status = CNContactStore.authorizationStatus(for: .contacts)
guard status == .authorized else { return }
```

**After:**
```swift
// TODO: Update ContactsSyncManager to use PermissionsManager.shared
guard PermissionsManager.shared.hasContactsAccess else { return }
```

## Benefits

### 🎯 No More Surprise Dialogs
Background coordinators **check** permissions but never **request** them. Only Settings UI requests permissions.

### 🎯 Consistent State
All parts of the app use the same EKEventStore and CNContactStore instances, avoiding per-instance cache issues.

### 🎯 Reactive Updates
SwiftUI views automatically update when permissions change via `@ObservedObject`.

### 🎯 Future-Proof
When you add email permissions later, you can extend PermissionsManager with:
```swift
@Published private(set) var emailStatus: ...
var hasEmailAccess: Bool { ... }
func requestEmailAccess() async -> Bool { ... }
```

## Usage Guidelines

### ✅ DO
- Call `permissions.hasContactsAccess` from coordinators/background tasks
- Call `await permissions.requestContactsAccess()` from Settings UI
- Use `permissions.eventStore` and `permissions.contactStore` everywhere
- Listen for `.permissionsDidChange` if you need to react to changes

### ❌ DON'T
- Call `CNContactStore.authorizationStatus()` directly (use the manager)
- Call `EKEventStore.authorizationStatus()` directly (use the manager)
- Request permissions from background tasks or coordinators
- Create your own EKEventStore or CNContactStore instances

## Testing

To verify the migration:
1. Launch app (permissions not determined)
2. Open Settings → Permissions tab
3. Click "Request Calendar Access" → dialog appears ✅
4. Grant permission → UI updates immediately ✅
5. Calendar picker becomes enabled ✅
6. Select a calendar → import runs automatically ✅
7. No additional dialogs appear ✅

Repeat for Contacts access.

## Future Email Integration

When adding email permissions:
```swift
// In PermissionsManager
@Published private(set) var emailStatus: ... 
var hasEmailAccess: Bool { emailStatus == .authorized }
func requestEmailAccess() async -> Bool { ... }

// In coordinators
guard permissions.hasEmailAccess else { return }
let emailStore = permissions.emailStore
```

The architecture scales cleanly to additional permission types.
