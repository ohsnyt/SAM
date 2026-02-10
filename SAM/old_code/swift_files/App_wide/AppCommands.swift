//
//  AppCommands.swift
//  SAM_crm
//
//  Defines app-wide keyboard shortcuts and menu commands.
//  Used in SAM_crmApp via the .commands() modifier.
//
//  Note: This approach uses @FocusedBinding to access app state from the scene.
//  The AppShellView exposes these bindings via .focusedSceneValue() modifiers.
//

import SwiftUI
import Combine

struct AppCommands: Commands {
    @FocusedBinding(\.showKeyboardShortcuts) var showKeyboardShortcuts: Bool?
    @FocusedBinding(\.sidebarSelection) var sidebarSelection: String?
    
    var body: some Commands {
        // Navigation commands
        CommandGroup(after: .sidebar) {
            Section("Navigation") {
                Button("Go to Awareness") {
                    sidebarSelection = SidebarItem.awareness.rawValue
                }
                .keyboardShortcut("1", modifiers: .command)
                
                Button("Go to People") {
                    sidebarSelection = SidebarItem.people.rawValue
                }
                .keyboardShortcut("2", modifiers: .command)
                
                Button("Go to Contexts") {
                    sidebarSelection = SidebarItem.contexts.rawValue
                }
                .keyboardShortcut("3", modifiers: .command)
                
                Button("Go to Inbox") {
                    sidebarSelection = SidebarItem.inbox.rawValue
                }
                .keyboardShortcut("4", modifiers: .command)
                
                Divider()
            }
        }
        
        // Help commands
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") {
                showKeyboardShortcuts = true
            }
            .keyboardShortcut("/", modifiers: .command)
            
            Divider()
            
            // Standard help items can be added here
            // Link("SAM Help", destination: URL(string: "https://...")!)
        }
    }
}
