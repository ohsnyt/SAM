//
//  KeyboardShortcutsView.swift
//  SAM_crm
//
//  Keyboard shortcuts palette - shows all available shortcuts in the app.
//  Invoked with ⌘/ following macOS conventions.
//

import SwiftUI

struct KeyboardShortcutsView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Keyboard Shortcuts")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding()
            
            Divider()
            
            // Shortcuts List
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ShortcutSection(title: "Navigation", shortcuts: [
                        ShortcutItem(key: "1", modifiers: "⌘", description: "Go to Awareness"),
                        ShortcutItem(key: "2", modifiers: "⌘", description: "Go to People"),
                        ShortcutItem(key: "3", modifiers: "⌘", description: "Go to Contexts"),
                        ShortcutItem(key: "4", modifiers: "⌘", description: "Go to Inbox"),
                        ShortcutItem(key: "F", modifiers: "⌘", description: "Focus Search Field"),
                        ShortcutItem(key: "[", modifiers: "⌘", description: "Go Back"),
                        ShortcutItem(key: "]", modifiers: "⌘", description: "Go Forward"),
                    ])
                    
                    ShortcutSection(title: "List Navigation", shortcuts: [
                        ShortcutItem(key: "↑/↓", modifiers: "", description: "Navigate list items"),
                        ShortcutItem(key: "Return", modifiers: "", description: "Select item"),
                        ShortcutItem(key: "Space", modifiers: "", description: "Quick preview"),
                    ])
                    
                    ShortcutSection(title: "People", shortcuts: [
                        ShortcutItem(key: "N", modifiers: "⌘", description: "New Person"),
                        ShortcutItem(key: "E", modifiers: "⌘", description: "Send Email"),
                        ShortcutItem(key: "O", modifiers: "⌘⇧", description: "Open in Contacts"),
                        ShortcutItem(key: "T", modifiers: "⌘", description: "Schedule Event"),
                        ShortcutItem(key: "K", modifiers: "⌘", description: "Add to Context"),
                    ])
                    
                    ShortcutSection(title: "Contexts", shortcuts: [
                        ShortcutItem(key: "N", modifiers: "⌘", description: "New Context"),
                    ])
                    
                    ShortcutSection(title: "Inbox", shortcuts: [
                        ShortcutItem(key: "D", modifiers: "⌘", description: "Mark Done"),
                        ShortcutItem(key: "T", modifiers: "⌘", description: "Toggle Full Text"),
                    ])
                    
                    ShortcutSection(title: "General", shortcuts: [
                        ShortcutItem(key: "/", modifiers: "⌘", description: "Show Keyboard Shortcuts"),
                        ShortcutItem(key: ",", modifiers: "⌘", description: "Open Settings"),
                        ShortcutItem(key: "W", modifiers: "⌘", description: "Close Window"),
                        ShortcutItem(key: "Q", modifiers: "⌘", description: "Quit SAM"),
                    ])
                }
                .padding()
            }
        }
        .frame(width: 500, height: 600)
    }
}

// MARK: - Supporting Views

private struct ShortcutSection: View {
    let title: String
    let shortcuts: [ShortcutItem]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            
            VStack(spacing: 8) {
                ForEach(shortcuts) { shortcut in
                    ShortcutRow(item: shortcut)
                }
            }
        }
    }
}

private struct ShortcutRow: View {
    let item: ShortcutItem
    
    var body: some View {
        HStack {
            Text(item.description)
                .font(.body)
            
            Spacer()
            
            HStack(spacing: 4) {
                if !item.modifiers.isEmpty {
                    Text(item.modifiers)
                        .font(.system(.body, design: .rounded))
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                }
                
                Text(item.key)
                    .font(.system(.body, design: .rounded))
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
        )
    }
}

private struct ShortcutItem: Identifiable {
    let id = UUID()
    let key: String
    let modifiers: String
    let description: String
}

// MARK: - Preview

#Preview {
    KeyboardShortcutsView()
}
