//
//  AppShellView.swift
//  SAM_crm
//
//  Created by Assistant on 2/9/26.
//  Clean rebuild - Phase A: Foundation
//
//  Main navigation container for the app.
//  Manages the NavigationSplitView with sidebar and detail routing.
//

import SwiftUI
import SwiftData

struct AppShellView: View {
    
    // MARK: - Navigation State
    
    @AppStorage("sam.sidebar.selection") private var sidebarSelection: String = "awareness"
    
    // MARK: - Body
    
    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .navigationTitle("SAM")
    }
    
    // MARK: - Sidebar
    
    private var sidebar: some View {
        List(selection: $sidebarSelection) {
            Section("Intelligence") {
                NavigationLink(value: "awareness") {
                    Label("Awareness", systemImage: "brain.head.profile")
                }
                
                NavigationLink(value: "inbox") {
                    Label("Inbox", systemImage: "tray")
                }
            }
            
            Section("Relationships") {
                NavigationLink(value: "people") {
                    Label("People", systemImage: "person.2")
                }
                
                NavigationLink(value: "contexts") {
                    Label("Contexts", systemImage: "building.2")
                }
            }
        }
        .navigationTitle("SAM")
        .frame(minWidth: 200)
    }
    
    // MARK: - Detail Routing
    
    @ViewBuilder
    private var detailView: some View {
        switch sidebarSelection {
        case "awareness":
            AwarenessPlaceholder()
            
        case "inbox":
            InboxPlaceholder()
            
        case "people":
            PeoplePlaceholder()
            
        case "contexts":
            ContextsPlaceholder()
            
        default:
            ContentUnavailableView(
                "Select an item",
                systemImage: "sidebar.left",
                description: Text("Choose a section from the sidebar")
            )
        }
    }
}

// MARK: - Placeholders (Phase A)

private struct AwarenessPlaceholder: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            
            Text("Awareness")
                .font(.title)
            
            Text("AI-powered insights will appear here")
                .foregroundStyle(.secondary)
            
            Text("Coming in Phase H")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct InboxPlaceholder: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "tray")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            
            Text("Inbox")
                .font(.title)
            
            Text("Evidence items needing review will appear here")
                .foregroundStyle(.secondary)
            
            Text("Coming in Phase F")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PeoplePlaceholder: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.2")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            
            Text("People")
                .font(.title)
            
            Text("Your contacts and relationships will appear here")
                .foregroundStyle(.secondary)
            
            Text("Coming in Phase D")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ContextsPlaceholder: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "building.2")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            
            Text("Contexts")
                .font(.title)
            
            Text("Households, businesses, and recruiting contexts will appear here")
                .foregroundStyle(.secondary)
            
            Text("Coming in Phase G")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview

#Preview {
    AppShellView()
        .modelContainer(SAMModelContainer.shared)
        .frame(width: 900, height: 600)
}
