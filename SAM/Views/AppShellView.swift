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
    @State private var selectedEvidenceID: UUID?
    @State private var selectedContextID: UUID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var postMeetingPayload: PostMeetingPayload?
    @Environment(\.openWindow) private var openWindow
    
    // MARK: - Body
    
    var body: some View {
        if sidebarSelection == "people" || sidebarSelection == "inbox" || sidebarSelection == "contexts" {
            // Three-column layout for People, Inbox, and Contexts sections
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebar
                    .navigationSplitViewColumnWidth(min: 120, ideal: 130, max: 200)
            } content: {
                threeColumnContent
                    .navigationSplitViewColumnWidth(min: 200, ideal: 280, max: 500)
            } detail: {
                threeColumnDetail
            }
            .navigationTitle("SAM")
            .onReceive(NotificationCenter.default.publisher(for: .samNavigateToPerson)) { notification in
                if let personID = notification.userInfo?["personID"] as? UUID {
                    sidebarSelection = "people"
                    selectedPersonID = personID
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .samOpenQuickNote)) { notification in
                if let payload = notification.userInfo?["payload"] as? QuickNotePayload {
                    openWindow(id: "quick-note", value: payload)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .samOpenPostMeetingCapture)) { notification in
                handlePostMeetingNotification(notification)
            }
            .sheet(item: $postMeetingPayload) { payload in
                PostMeetingCaptureView(
                    eventTitle: payload.eventTitle,
                    eventDate: payload.eventDate,
                    attendeeIDs: payload.attendeeIDs,
                    onSave: {}
                )
            }
            .overlay(alignment: .bottom) {
                UndoToastView()
            }
        } else {
            // Two-column layout for other sections
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 120, ideal: 130, max: 200)
            } detail: {
                detailView
            }
            .navigationTitle("SAM")
            .onReceive(NotificationCenter.default.publisher(for: .samNavigateToPerson)) { notification in
                if let personID = notification.userInfo?["personID"] as? UUID {
                    sidebarSelection = "people"
                    selectedPersonID = personID
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .samOpenQuickNote)) { notification in
                if let payload = notification.userInfo?["payload"] as? QuickNotePayload {
                    openWindow(id: "quick-note", value: payload)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .samOpenPostMeetingCapture)) { notification in
                handlePostMeetingNotification(notification)
            }
            .sheet(item: $postMeetingPayload) { payload in
                PostMeetingCaptureView(
                    eventTitle: payload.eventTitle,
                    eventDate: payload.eventDate,
                    attendeeIDs: payload.attendeeIDs,
                    onSave: {}
                )
            }
            .overlay(alignment: .bottom) {
                UndoToastView()
            }
        }
    }

    // MARK: - Post-Meeting Notification Handler

    private func handlePostMeetingNotification(_ notification: Notification) {
        guard let title = notification.userInfo?["eventTitle"] as? String,
              let date = notification.userInfo?["eventDate"] as? Date,
              let ids = notification.userInfo?["attendeeIDs"] as? [UUID] else { return }
        postMeetingPayload = PostMeetingPayload(eventTitle: title, eventDate: date, attendeeIDs: ids)
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

            Section("Business") {
                NavigationLink(value: "business") {
                    Label("Pipeline", systemImage: "chart.bar.horizontal.page")
                }
            }
        }
        .navigationTitle("SAM")
        .safeAreaInset(edge: .bottom) {
            ProcessingStatusView()
        }
    }
    
    // MARK: - Detail Routing
    
    @ViewBuilder
    private var detailView: some View {
        switch sidebarSelection {
        case "awareness":
            AwarenessView()

        case "business":
            BusinessDashboardView()

        default:
            ContentUnavailableView(
                "Select an item",
                systemImage: "sidebar.left",
                description: Text("Choose a section from the sidebar")
            )
        }
    }

    // MARK: - Three-Column Content (list column)

    @ViewBuilder
    private var threeColumnContent: some View {
        switch sidebarSelection {
        case "people":
            PeopleListView(selectedPersonID: $selectedPersonID)
        case "inbox":
            InboxListView(selectedEvidenceID: $selectedEvidenceID)
        case "contexts":
            ContextListView(selectedContextID: $selectedContextID)
        default:
            EmptyView()
        }
    }

    // MARK: - Three-Column Detail

    @ViewBuilder
    private var threeColumnDetail: some View {
        switch sidebarSelection {
        case "people":
            peopleDetailView
        case "inbox":
            inboxDetailView
        case "contexts":
            contextsDetailView
        default:
            EmptyView()
        }
    }

    // MARK: - People Detail View

    @ViewBuilder
    private var peopleDetailView: some View {
        if let selectedID = selectedPersonID {
            PeopleDetailContainer(personID: selectedID)
                .id(selectedID)
        } else {
            ContentUnavailableView(
                "Select a Person",
                systemImage: "person.circle",
                description: Text("Choose someone from the list to view their details")
            )
        }
    }

    // MARK: - Inbox Detail View

    @ViewBuilder
    private var inboxDetailView: some View {
        if let selectedID = selectedEvidenceID {
            InboxDetailContainer(evidenceID: selectedID)
                .id(selectedID)
        } else {
            ContentUnavailableView(
                "Select an Item",
                systemImage: "tray",
                description: Text("Choose an evidence item from the list to view its details")
            )
        }
    }

    // MARK: - Contexts Detail View

    @ViewBuilder
    private var contextsDetailView: some View {
        if let selectedID = selectedContextID {
            ContextsDetailContainer(contextID: selectedID)
                .id(selectedID)
        } else {
            ContentUnavailableView(
                "Select a Context",
                systemImage: "building.2",
                description: Text("Choose a context from the list to view its details")
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

// MARK: - Inbox Detail Container

/// Helper view that fetches an evidence item by ID and displays InboxDetailView
private struct InboxDetailContainer: View {
    let evidenceID: UUID

    @Query private var allItems: [SamEvidenceItem]

    var item: SamEvidenceItem? {
        allItems.first(where: { $0.id == evidenceID })
    }

    var body: some View {
        if let item = item {
            InboxDetailView(item: item)
                .id(evidenceID)
        } else {
            ContentUnavailableView(
                "Item Not Found",
                systemImage: "tray.slash",
                description: Text("This evidence item may have been deleted")
            )
        }
    }
}

// MARK: - Contexts Detail Container

/// Helper view that fetches a context by ID and displays ContextDetailView
private struct ContextsDetailContainer: View {
    let contextID: UUID

    @Query private var allContexts: [SamContext]

    var context: SamContext? {
        allContexts.first(where: { $0.id == contextID })
    }

    var body: some View {
        if let context = context {
            ContextDetailView(context: context)
                .id(contextID)
        } else {
            ContentUnavailableView(
                "Context Not Found",
                systemImage: "building.2.crop.circle.badge.questionmark",
                description: Text("This context may have been deleted")
            )
        }
    }
}

// MARK: - Preview

#Preview {
    AppShellView()
        .modelContainer(SAMModelContainer.shared)
        .frame(width: 900, height: 800)
}
