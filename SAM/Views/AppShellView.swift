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
    @State private var selectedPersonID: UUID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    
    // MARK: - Body
    
    var body: some View {
        if sidebarSelection == "people" {
            // Three-column layout for People section
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebar
                    .navigationSplitViewColumnWidth(min: 120, ideal: 130, max: 200)
            } content: {
                PeopleListView(selectedPersonID: $selectedPersonID)
                    .navigationSplitViewColumnWidth(min: 200, ideal: 280, max: 500)
            } detail: {
                peopleDetailView
            }
            .navigationTitle("SAM")
        } else {
            // Two-column layout for other sections
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 120, ideal: 130, max: 200)
            } detail: {
                detailView
            }
            .navigationTitle("SAM")
        }
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
    }
    
    // MARK: - Detail Routing
    
    @ViewBuilder
    private var detailView: some View {
        switch sidebarSelection {
        case "awareness":
            AwarenessPlaceholder()
            
        case "inbox":
            InboxPlaceholder()
            
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
    
    // MARK: - People Detail View
    
    @ViewBuilder
    private var peopleDetailView: some View {
        if let selectedID = selectedPersonID {
            PeopleDetailContainer(personID: selectedID)
                .id(selectedID)  // Force view to recreate when ID changes
        } else {
            ContentUnavailableView(
                "Select a Person",
                systemImage: "person.circle",
                description: Text("Choose someone from the list to view their details")
            )
        }
    }
}

// MARK: - People Detail Container

/// Helper view that fetches a person by ID and displays PersonDetailView
private struct PeopleDetailContainer: View {
    let personID: UUID
    
    @Query private var allPeople: [SamPerson]
    
    var person: SamPerson? {
        allPeople.first(where: { $0.id == personID })
    }
    
    var body: some View {
        if let person = person {
            PersonDetailView(person: person)
                .id(personID)  // Force PersonDetailView to recreate when person changes
        } else {
            ContentUnavailableView(
                "Person Not Found",
                systemImage: "person.crop.circle.badge.questionmark",
                description: Text("This person may have been deleted")
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
        .frame(width: 900, height: 800)
}
