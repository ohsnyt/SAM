//
//  AppFocusedValues.swift
//  SAM_crm
//
//  Focused value keys for app-wide state that needs to be accessed from Commands.
//  These allow keyboard shortcuts defined in AppCommands to access state from AppShellView.
//

import SwiftUI
import Combine

// MARK: - Focused Value Keys

struct ShowKeyboardShortcutsFocusedValueKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

struct SidebarSelectionFocusedValueKey: FocusedValueKey {
    typealias Value = Binding<String>
}

extension FocusedValues {
    var showKeyboardShortcuts: Binding<Bool>? {
        get { self[ShowKeyboardShortcutsFocusedValueKey.self] }
        set { self[ShowKeyboardShortcutsFocusedValueKey.self] = newValue }
    }
    
    var sidebarSelection: Binding<String>? {
        get { self[SidebarSelectionFocusedValueKey.self] }
        set { self[SidebarSelectionFocusedValueKey.self] = newValue }
    }
}
