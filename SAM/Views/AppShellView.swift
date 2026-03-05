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

    fileprivate enum PeopleMode: String { case contacts, graph }

    @AppStorage("sam.sidebar.selection") private var sidebarSelection: String = "today"
    @State private var selectedPersonID: UUID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var postMeetingPayload: PostMeetingPayload?
    @State private var showCommandPalette = false
    @State private var introCoordinator = IntroSequenceCoordinator.shared
    @State private var peopleMode: PeopleMode = .contacts
    @AppStorage("sam.tips.guidanceEnabled") private var tipsEnabled: Bool = true
    @Environment(\.openWindow) private var openWindow

    
    // MARK: - Body
    
    var body: some View {
        Group {
            if sidebarSelection == "people" && peopleMode == .contacts {
                // Three-column layout for People > Contacts
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
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        peopleModeToolbar
                    }
                }
            } else if sidebarSelection == "people" && peopleMode == .graph {
                // Two-column layout for People > Graph
                NavigationSplitView {
                    sidebar
                        .navigationSplitViewColumnWidth(min: 120, ideal: 130, max: 200)
                } detail: {
                    RelationshipGraphView()
                }
                .navigationTitle("SAM")
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        peopleModeToolbar
                    }
                }
            } else {
                // Two-column layout for Today, Business, Grow, Search
                NavigationSplitView {
                    sidebar
                        .navigationSplitViewColumnWidth(min: 120, ideal: 130, max: 200)
                } detail: {
                    detailView
                }
                .navigationTitle("SAM")
            }
        }
        .tipViewStyle(SAMTipViewStyle())
        .modifier(AppShellNotificationHandlers(
            sidebarSelection: $sidebarSelection,
            selectedPersonID: $selectedPersonID,
            postMeetingPayload: $postMeetingPayload,
            peopleMode: $peopleMode,
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
        .onAppear {
            // Show intro only if onboarding is already complete (returning user who
            // hasn't seen intro yet, e.g. after a Reset Intro). First-launch case
            // is handled sequentially from onboarding's onDisappear in SAMApp.
            let onboardingDone = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
            if onboardingDone {
                introCoordinator.checkAndShow()
            }
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

    // MARK: - People Mode Toolbar

    private var peopleModeToolbar: some View {
        Picker("", selection: $peopleMode) {
            Text("Contacts").tag(PeopleMode.contacts)
            Text("Graph").tag(PeopleMode.graph)
        }
        .pickerStyle(.segmented)
        .frame(width: 180)
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

            NavigationLink(value: "grow") {
                Label("Grow", systemImage: "arrow.up.right.circle")
            }

            NavigationLink(value: "search") {
                Label("Search", systemImage: "magnifyingglass")
            }
        }
        .navigationTitle("SAM")
        .safeAreaInset(edge: .top) {
            if tipsEnabled {
                Text("Use ⌘K for quick navigation, ⌘1–5 to jump between sections.")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                MinionsView()

                Divider()

                // Tips toggle — orange background when on, plain when off
                Button {
                    if tipsEnabled {
                        SAMTipState.disableTips()
                        tipsEnabled = false
                    } else {
                        SAMTipState.enableTips()
                        tipsEnabled = true
                    }
                } label: {
                    Label(
                        tipsEnabled ? "Tips On" : "Tips Off",
                        systemImage: tipsEnabled
                            ? "questionmark.circle.fill"
                            : "questionmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(tipsEnabled ? Color.white : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        tipsEnabled
                            ? Color.orange.opacity(0.85).clipShape(RoundedRectangle(cornerRadius: 8))
                            : nil
                    )
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.plain)
                .help(tipsEnabled ? "Hide tips" : "Show tips")
            }
        }
        .onAppear {
            // Migrate stale @AppStorage values from old sidebar items
            switch sidebarSelection {
            case "awareness", "inbox":
                sidebarSelection = "today"
            case "contexts":
                sidebarSelection = "people"
            case "graph":
                sidebarSelection = "people"
                peopleMode = .graph
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

        case "grow":
            GrowDashboardView()

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
    @Binding var peopleMode: AppShellView.PeopleMode
    let openWindow: OpenWindowAction

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .samNavigateToPerson)) { notification in
                if let personID = notification.userInfo?["personID"] as? UUID {
                    sidebarSelection = "people"
                    peopleMode = .contacts
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
                sidebarSelection = "people"
                peopleMode = .graph
                if let focusMode = notification.userInfo?["focusMode"] as? String {
                    RelationshipGraphCoordinator.shared.activateFocusMode(focusMode)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .samNavigateToStrategicInsights)) { _ in
                sidebarSelection = "business"
            }
            .onReceive(NotificationCenter.default.publisher(for: .samNavigateToGrow)) { _ in
                sidebarSelection = "grow"
            }
            .onReceive(NotificationCenter.default.publisher(for: .samOpenClipboardCapture)) { _ in
                let payload = ClipboardCapturePayload(captureID: UUID())
                openWindow(id: "clipboard-capture", value: payload)
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
