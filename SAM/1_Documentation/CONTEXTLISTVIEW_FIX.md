# Fix for ContextListView.swift Compile Errors

## Problem

The `ContextKind` enum has more cases than `.household` and `.business`, causing "Switch must be exhaustive" errors in three places in the ContextListView.swift extensions.

## Solution

Add `@unknown default` cases to all three switch statements in the `ContextKind` extension at the bottom of ContextListView.swift (around line 330-360).

## Code Changes

Find this code near the end of ContextListView.swift:

```swift
extension ContextKind {
    var displayName: String {
        switch self {
        case .household:
            return "Household"
        case .business:
            return "Business"
        }
    }
    
    var icon: String {
        switch self {
        case .household:
            return "house.fill"
        case .business:
            return "building.2.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .household:
            return .blue
        case .business:
            return .purple
        }
    }
}
```

Replace it with:

```swift
extension ContextKind {
    var displayName: String {
        switch self {
        case .household:
            return "Household"
        case .business:
            return "Business"
        @unknown default:
            return rawValue.capitalized
        }
    }
    
    var icon: String {
        switch self {
        case .household:
            return "house.fill"
        case .business:
            return "building.2.fill"
        @unknown default:
            return "folder.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .household:
            return .blue
        case .business:
            return .purple
        @unknown default:
            return .gray
        }
    }
}
```

## Explanation

The `@unknown default` case handles any additional cases that might be added to `ContextKind` in the future (or that already exist but we're not handling yet). This is a safer pattern than just `default` because it will still give a compiler warning if new cases are added, but allows the code to compile and run with a fallback behavior.

The fallback behaviors are:
- **displayName**: Uses the enum's raw value, capitalized
- **icon**: Uses a generic folder icon
- **color**: Uses gray

This ensures the app won't crash if it encounters an unexpected context kind.
