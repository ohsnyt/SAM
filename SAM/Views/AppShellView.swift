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
import TipKit

struct AppShellView: View {
    
    // MARK: - Navigation State
    
    @AppStorage("sam.sidebar.selection") private var sidebarSelection: String = "today"
    @State private var selectedPersonID: UUID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var postMeetingPayload: PostMeetingPayload?
    @State private var showCommandPalette = false
    @State private var introCoordinator = IntroSequenceCoordinator.shared
    @Environment(\.openWindow) private var openWindow
    private let commandPaletteTip = CommandPaletteTip()
    
    // MARK: - Body
    
    var body: some View {
        Group {
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
                // Two-column layout for Today, Business, Search
                NavigationSplitView {
                    sidebar
                        .navigationSplitViewColumnWidth(min: 120, ideal: 130, max: 200)
                } detail: {
                    detailView
                }
                .navigationTitle("SAM")
            }
        }
        .modifier(AppShellNotificationHandlers(
            sidebarSelection: $sidebarSelection,
            selectedPersonID: $selectedPersonID,
            postMeetingPayload: $postMeetingPayload,
            openWindow: openWindow
        ))
        .sheet(item: $postMeetingPayload) { payload in
            PostMeetingCaptureView(
                eventTitle: payload.eventTitle,
                eventDate: payload.eventDate,
                attendeeIDs: payload.attendeeIDs,
                onSave: {}
            )
        }
        .sheet(isPresented: $showCommandPalette) {
            CommandPaletteView(
                onNavigate: { section in
                    sidebarSelection = section
                },
                onSelectPerson: { personID in
                    sidebarSelection = "people"
                    selectedPersonID = personID
                },
                onDismiss: {
                    showCommandPalette = false
                }
            )
        }
        .overlay(alignment: .bottom) {
            UndoToastView()
        }
        .sheet(isPresented: Binding(
            get: { introCoordinator.showIntroSequence },
            set: { introCoordinator.showIntroSequence = $0 }
        )) {
            IntroSequenceOverlay()
                .interactiveDismissDisabled()
        }
        .task(id: "introCheck") {
            // Brief delay so main UI renders first
            try? await Task.sleep(for: .milliseconds(300))
            introCoordinator.checkAndShow()
        }
        .onReceive(NotificationCenter.default.publisher(for: .samToggleCommandPalette)) { _ in
            showCommandPalette.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .samNavigateToSection)) { notification in
            if let section = notification.userInfo?["section"] as? String {
                sidebarSelection = section
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $sidebarSelection) {
            NavigationLink(value: "today") {
                Label("Today", systemImage: "sun.max")
            }

            NavigationLink(value: "people") {
                Label("People", systemImage: "person.2")
            }

            NavigationLink(value: "business") {
                Label("Business", systemImage: "chart.bar.horizontal.page")
            }

            NavigationLink(value: "search") {
                Label("Search", systemImage: "magnifyingglass")
            }
        }
        .navigationTitle("SAM")
        .popoverTip(commandPaletteTip, arrowEdge: .trailing)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    let newValue = !SAMTipState.guidanceEnabled
                    SAMTipState.guidanceEnabled = newValue
                    if newValue { try? Tips.resetDatastore() }
                } label: {
                    Image(systemName: SAMTipState.guidanceEnabled
                          ? "questionmark.circle.fill"
                          : "questionmark.circle")
                }
                .help(SAMTipState.guidanceEnabled ? "Hide tips" : "Show tips")
            }
        }
        .safeAreaInset(edge: .bottom) {
            ProcessingStatusView()
        }
        .onAppear {
            // Migrate stale @AppStorage values from old sidebar items
            switch sidebarSelection {
            case "awareness", "inbox":
                sidebarSelection = "today"
            case "contexts":
                sidebarSelection = "people"
            case "graph":
                sidebarSelection = "business"
            default:
                break
            }
        }
    }
    
    // MARK: - Detail Routing
    
    @ViewBuilder
    private var detailView: some View {
        switch sidebarSelection {
        case "today":
            AwarenessView()

        case "business":
            BusinessDashboardView()

        case "search":
            SearchView()

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
                .id(selectedID)
        } else {
            ContentUnavailableView(
                "Select a Person",
                systemImage: "person.circle",
                description: Text("Choose someone from the list to view their details")
            )
        }
    }

}

// MARK: - Notification Handlers (shared between layout branches)

private struct AppShellNotificationHandlers: ViewModifier {
    @Binding var sidebarSelection: String
    @Binding var selectedPersonID: UUID?
    @Binding var postMeetingPayload: PostMeetingPayload?
    let openWindow: OpenWindowAction

    func body(content: Content) -> some View {
        content
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
                guard let title = notification.userInfo?["eventTitle"] as? String,
                      let date = notification.userInfo?["eventDate"] as? Date,
                      let ids = notification.userInfo?["attendeeIDs"] as? [UUID] else { return }
                postMeetingPayload = PostMeetingPayload(eventTitle: title, eventDate: date, attendeeIDs: ids)
            }
            .onReceive(NotificationCenter.default.publisher(for: .samNavigateToGraph)) { notification in
                sidebarSelection = "business"
                if let focusMode = notification.userInfo?["focusMode"] as? String {
                    RelationshipGraphCoordinator.shared.activateFocusMode(focusMode)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .samNavigateToStrategicInsights)) { _ in
                sidebarSelection = "business"
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



// MARK: - Preview

#Preview {
    AppShellView()
        .modelContainer(SAMModelContainer.shared)
        .frame(width: 900, height: 800)
}
