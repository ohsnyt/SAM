# Keyboard Shortcuts Fix

## Problem
Keyboard shortcuts (⌘/, ⌘1-4, etc.) were not working because they weren't properly registered with the app's command system.

## Solution
Implemented proper SwiftUI keyboard shortcuts using the `.commands()` modifier pattern and `@FocusedBinding`.

## Files Created/Modified

### New Files
1. **AppCommands.swift** - Defines all app-wide keyboard shortcuts as menu commands
2. **AppFocusedValues.swift** - Focused value keys that connect AppShellView state to commands
3. **KeyEventMonitor.swift** - *(No longer needed, can be deleted)*

### Modified Files
1. **AppShellView.swift** - Now exposes state via `.focusedSceneValue()` modifiers

## Integration Required

You need to add the `AppCommands` to your main App file (`SAM_crmApp.swift` or similar).

### Add this to your @main App struct:

```swift
import SwiftUI
import SwiftData

@main
struct SAM_crmApp: App {
    var body: some Scene {
        WindowGroup {
            AppShellView()
                .modelContainer(SAMModelContainer.shared)
        }
        .commands {
            AppCommands()  // ⭐️ ADD THIS LINE
        }
        
        // Your Settings scene here...
        Settings {
            SamSettingsView()
        }
    }
}
```

## How It Works

### 1. AppCommands (Menu Bar Integration)
The `AppCommands` struct uses `@FocusedBinding` to access state from the currently focused scene:
- `showKeyboardShortcuts` - Opens/closes the shortcuts palette
- `sidebarSelection` - Changes which sidebar item is selected

### 2. AppShellView (State Exposure)
AppShellView exposes its `@State` variables as focused values:
```swift
.focusedSceneValue(\.showKeyboardShortcuts, $showKeyboardShortcuts)
.focusedSceneValue(\.sidebarSelection, $selectionRaw)
```

### 3. Keyboard Shortcuts Registration
When you add `.commands { AppCommands() }` to your App, SwiftUI automatically:
- Registers the keyboard shortcuts (⌘/, ⌘1, ⌘2, ⌘3, ⌘4)
- Adds menu items to the menu bar under "Go" and "Help"
- Handles the shortcuts system-wide (works even when no specific control has focus)

## Shortcuts Available

### Navigation
- **⌘1** - Go to Awareness
- **⌘2** - Go to People
- **⌘3** - Go to Contexts
- **⌘4** - Go to Inbox

### Help
- **⌘/** - Show Keyboard Shortcuts Palette

### Context-Specific (already working)
These were defined with `.keyboardShortcut()` on buttons and will continue to work:
- **⌘N** - New Person/Context
- **⌘E** - Email (People detail)
- **⌘⇧O** - Open in Contacts
- **⌘T** - Schedule/Toggle
- **⌘K** - Add to Context
- **⌘D** - Mark Done (Inbox)

## Testing

After adding `AppCommands()` to your `.commands` block:

1. **Check Menu Bar**: Look in the "Go" menu - you should see navigation shortcuts
2. **Check Help Menu**: Should show "Keyboard Shortcuts" with ⌘/
3. **Test Shortcuts**: Press ⌘/ to open the keyboard shortcuts palette
4. **Test Navigation**: Press ⌘1, ⌘2, ⌘3, ⌘4 to switch sidebar items

## Why This Approach?

### ❌ NSEvent Monitoring (Previous Attempt)
- Doesn't integrate with SwiftUI's focus system
- Can't access SwiftUI state safely
- Requires manual AppKit bridging
- Doesn't show up in menu bar
- Harder to maintain

### ✅ SwiftUI Commands (Current Solution)
- Native SwiftUI pattern
- Automatic menu bar integration
- Discoverability (users can see shortcuts in menus)
- Safe state access via `@FocusedBinding`
- Respects SwiftUI's focus and responder chain
- Platform-appropriate (follows macOS HIG)

## Additional Notes

### Menu Bar Visibility
The keyboard shortcuts will now appear in your app's menu bar:
- **Go** menu: Navigation shortcuts (⌘1-4)
- **Help** menu: Keyboard shortcuts palette (⌘/)

This follows macOS Human Interface Guidelines and makes shortcuts discoverable.

### Focused Values vs Environment Values
We use `@FocusedBinding` instead of `@Environment` because:
- Commands exist at the app level, outside the view hierarchy
- Focused values propagate through the responder chain
- This allows commands to work with the active window's state

### Cleanup
You can safely delete:
- `KeyEventMonitor.swift` (no longer needed)

The old approach tried to catch keyboard events manually, but SwiftUI's `.commands()` is the proper way to handle app-wide shortcuts on macOS.
