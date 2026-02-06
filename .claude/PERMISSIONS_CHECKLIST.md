# Permissions Refactoring Checklist

## ✅ Completed Changes

### New Files Created
- ✅ **PermissionsManager.swift** - Centralized permissions management
- ✅ **PERMISSIONS_REFACTOR.md** - Architecture documentation

### Files Updated

#### ✅ ContactsImportCoordinator.swift
- Removed: `static let contactStore = CNContactStore()`
- Added: `private let permissions = PermissionsManager.shared`
- Replaced: Direct `CNContactStore.authorizationStatus()` calls with `permissions.hasContactsAccess`
- Replaced: Local `requestAccess()` call with permission check only
- Uses: `permissions.contactStore` instead of `Self.contactStore`

#### ✅ CalendarImportCoordinator.swift
- Removed: `static let eventStore = EKEventStore()`
- Added: `private let permissions = PermissionsManager.shared`
- Replaced: Direct `EKEventStore.authorizationStatus()` calls with `permissions.hasFullCalendarAccess`
- Uses: `permissions.eventStore` instead of `Self.eventStore`
- Updated: `ContactsResolver` to use `PermissionsManager.shared.contactStore`

#### ✅ SamSettingsView.swift
- Removed: `@State private var calendarAuthStatus` and `contactsAuthStatus`
- Removed: `private static let contactStore = CNContactStore()`
- Removed: `refreshAuthStatuses()` method
- Removed: `statusText()` helper methods (moved to PermissionsManager)
- Added: `@ObservedObject private var permissions = PermissionsManager.shared`
- Updated: All permission request methods to use `permissions.requestCalendarAccess()` / `requestContactsAccess()`
- Updated: All store references to use `permissions.eventStore` / `permissions.contactStore`
- Updated: `PermissionsTab`, `ImportTab`, and `ContactsTab` to use value types instead of `@Binding` for auth status

#### ✅ InboxDetailView.swift
- Replaced: `CNContactStore.authorizationStatus(for: .contacts)` with `PermissionsManager.shared.hasContactsAccess`
- Replaced: Local `CNContactStore()` instantiation with `PermissionsManager.shared.contactStore`

### Files That Don't Need Changes

#### ✅ SAM_crmApp.swift
- No changes needed
- Already observes `.EKEventStoreChanged` and `.CNContactStoreDidChange`
- Coordinators will continue to work with the new architecture

## 🔍 Files to Review (Not Yet Updated)

### ContactsSyncManager.swift
- **Current**: `CNContactStore.authorizationStatus(for: .contacts) == .authorized`
- **Should be**: `PermissionsManager.shared.hasContactsAccess`
- **Note**: This file creates its own contact stores and validators. Consider updating to use the centralized manager.

## 🧪 Testing Checklist

### Scenario 1: Fresh Launch (No Permissions)
- [ ] Launch app with no permissions granted
- [ ] Open Settings → Permissions tab
- [ ] Click "Request Calendar Access"
- [ ] Verify: System permission dialog appears
- [ ] Grant permission
- [ ] Verify: Calendar picker becomes enabled
- [ ] Verify: Status shows "Granted (Full Access)"
- [ ] Verify: No additional dialogs appear

### Scenario 2: Fresh Launch (No Permissions) - Contacts
- [ ] Open Settings → Permissions tab  
- [ ] Click "Request Contacts Access"
- [ ] Verify: System permission dialog appears
- [ ] Grant permission
- [ ] Verify: Contacts group picker becomes enabled
- [ ] Verify: Status shows "Granted"
- [ ] Verify: No additional dialogs appear

### Scenario 3: Background Sync (Permissions Already Granted)
- [ ] Grant both Calendar and Contacts permissions
- [ ] Select a calendar and contacts group
- [ ] Enable Calendar Import and Contacts Integration
- [ ] Quit and relaunch app
- [ ] Verify: No permission dialogs appear
- [ ] Verify: Import runs automatically in background
- [ ] Verify: Evidence appears in Inbox

### Scenario 4: Permission Revoked While App Running
- [ ] Launch app with permissions granted
- [ ] Open System Settings → Privacy & Security → Calendars
- [ ] Revoke SAM's calendar permission
- [ ] Return to SAM
- [ ] Verify: Settings UI updates to show "Denied"
- [ ] Verify: Calendar import stops working
- [ ] Re-grant permission in System Settings
- [ ] Return to SAM  
- [ ] Verify: Settings UI updates to show "Granted"
- [ ] Verify: Import resumes automatically

### Scenario 5: Multiple Windows
- [ ] Open Settings window
- [ ] Open main app window
- [ ] Grant permissions in Settings
- [ ] Verify: Main window can immediately use permissions
- [ ] Verify: No duplicate permission dialogs

## 🎯 Key Benefits Achieved

### ✅ Single Source of Truth
All parts of the app use:
- `PermissionsManager.shared.eventStore` (one EKEventStore instance)
- `PermissionsManager.shared.contactStore` (one CNContactStore instance)
- `PermissionsManager.shared.hasCalendarAccess` (no direct status checks)
- `PermissionsManager.shared.hasContactsAccess` (no direct status checks)

### ✅ No Surprise Dialogs
- Permission requests **only** happen in Settings UI
- Background coordinators **check** permissions but never **request** them
- The distinction is clear: `hasContactsAccess` vs `requestContactsAccess()`

### ✅ Automatic UI Updates
- SwiftUI views observe `PermissionsManager` via `@ObservedObject`
- When permissions change, UI updates automatically
- No manual `refreshAuthStatuses()` calls needed

### ✅ Future-Proof
When adding email permissions:
```swift
// In PermissionsManager.swift
@Published private(set) var emailStatus: ...
var hasEmailAccess: Bool { ... }
func requestEmailAccess() async -> Bool { ... }
```

All coordinators follow the same pattern:
```swift
guard permissions.hasEmailAccess else { return }
let emailStore = permissions.emailStore
```

## 📝 Migration Notes for Team

### Before
```swift
// ❌ OLD: Direct authorization checks scattered everywhere
let status = CNContactStore.authorizationStatus(for: .contacts)
guard status == .authorized else { return }

// ❌ OLD: Each file creates its own store
static let contactStore = CNContactStore()
```

### After
```swift
// ✅ NEW: Centralized permission check (no dialog)
guard PermissionsManager.shared.hasContactsAccess else { return }

// ✅ NEW: Use the shared store
let contactStore = PermissionsManager.shared.contactStore
```

### For UI Code (Settings)
```swift
// ✅ REQUEST permissions (shows dialog)
await permissions.requestContactsAccess()
```

### For Background Code (Coordinators)
```swift
// ✅ CHECK permissions (no dialog)
guard permissions.hasContactsAccess else { return }
```

## 🚀 Next Steps

1. **Test thoroughly** using the checklist above
2. **Update ContactsSyncManager** to use PermissionsManager (optional but recommended)
3. **Remove any remaining direct** `CNContactStore.authorizationStatus()` or `EKEventStore.authorizationStatus()` calls
4. **Document** the pattern for future developers (link to PERMISSIONS_REFACTOR.md)
5. **Plan email integration** using the same architecture

## ⚠️ Breaking Changes

### For External Code
If any other files create their own `EKEventStore` or `CNContactStore` instances, they should be updated to use `PermissionsManager.shared`.

### For Tests
Mock `PermissionsManager` if needed:
```swift
// Test helper
extension PermissionsManager {
    static func mockWithPermissions(calendar: Bool, contacts: Bool) -> PermissionsManager {
        // ... return test instance
    }
}
```

## 📚 Documentation

See **PERMISSIONS_REFACTOR.md** for:
- Detailed architecture overview
- Before/after code examples
- Usage guidelines (DO/DON'T)
- Future email integration plan
