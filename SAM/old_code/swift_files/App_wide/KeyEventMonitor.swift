//
//  KeyEventMonitor.swift
//  SAM_crm
//
//  Monitors keyboard events for app-wide shortcuts.
//  This invisible view installs a local event monitor to catch keyboard shortcuts
//  that aren't handled by standard SwiftUI `.keyboardShortcut()` modifiers.
//

import SwiftUI
import AppKit
import Combine

struct KeyEventMonitor: NSViewRepresentable {
    @Binding var showKeyboardShortcuts: Bool
    @Binding var selectionRaw: String
    
    func makeNSView(context: Context) -> NSView {
        let view = MonitoringView()
        
        // Install local monitor for key events
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Check for Command key
            let commandPressed = event.modifierFlags.contains(.command)
            let shiftPressed = event.modifierFlags.contains(.shift)
            
            // ⌘/ - Show keyboard shortcuts palette
            if commandPressed && !shiftPressed && event.charactersIgnoringModifiers == "/" {
                DispatchQueue.main.async {
                    showKeyboardShortcuts = true
                }
                return nil // Consume event
            }
            
            // ⌘1 through ⌘4 - Navigation shortcuts
            if commandPressed && !shiftPressed {
                switch event.charactersIgnoringModifiers {
                case "1":
                    DispatchQueue.main.async {
                        selectionRaw = SidebarItem.awareness.rawValue
                    }
                    return nil
                case "2":
                    DispatchQueue.main.async {
                        selectionRaw = SidebarItem.people.rawValue
                    }
                    return nil
                case "3":
                    DispatchQueue.main.async {
                        selectionRaw = SidebarItem.contexts.rawValue
                    }
                    return nil
                case "4":
                    DispatchQueue.main.async {
                        selectionRaw = SidebarItem.inbox.rawValue
                    }
                    return nil
                default:
                    break
                }
            }
            
            // Pass through unhandled events
            return event
        }
        
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        // No updates needed
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        // Clean up event monitor when view is removed
        if let monitor = coordinator.monitor {
            NSEvent.removeMonitor(monitor)
            coordinator.monitor = nil
        }
    }
    
    class Coordinator {
        var monitor: Any?
    }
}

/// Invisible view that exists solely to participate in the responder chain
private class MonitoringView: NSView {
    override var acceptsFirstResponder: Bool { true }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Make sure we're in the responder chain
        window?.makeFirstResponder(self)
    }
}
