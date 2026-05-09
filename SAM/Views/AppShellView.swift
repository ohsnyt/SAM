//
//  AppShellView.swift
//  SAM_crm
//
//  Created by Assistant on 2/9/26.
//  Clean rebuild - Phase A: Foundation
//
//  Main navigation container for the app.
//  Manages a single NavigationSplitView with sidebar and detail routing.
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
    @State private var capturePayload: CapturePayload?
    @State private var impromptuReviewPayload: ImpromptuReviewPayload?
    @State private var showCommandPalette = false
    @State private var introCoordinator = IntroSequenceCoordinator.shared
    @State private var noteAnalysisCoordinator = NoteAnalysisCoordinator.shared
    @State private var peopleMode: PeopleMode = .contacts
    @State private var peopleSpecialFilters: Set<PeopleSpecialFilter> = []
    @State private var eventSection: EventManagerView.EventSection = .events
    @Environment(\.openWindow) private var openWindow

    /// Whether the People section shows the contact list + detail side by side.
    private var showPeopleList: Bool {
        sidebarSelection == "people" && peopleMode == .contacts
    }

    // MARK: - Body

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 120, ideal: 130, max: 200)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detailView
        }
        .navigationTitle("SAM")
        .toolbar(removing: .sidebarToggle)
        .background { SidebarToggleConfigurator() }
        .toolbar {
            if sidebarSelection == "people" {
                ToolbarItem(placement: .principal) {
                    peopleModeToolbar
                }
            }
            if sidebarSelection == "events" {
                ToolbarItem(placement: .principal) {
                    eventSectionToolbar
                }
                ToolbarItem(placement: .primaryAction) {
                    GuideButton(articleID: "events.overview")
                }
            }
        }
        .tipViewStyle(SAMTipViewStyle())
        .modifier(AppShellNotificationHandlers(
            sidebarSelection: $sidebarSelection,
            selectedPersonID: $selectedPersonID,
            capturePayload: $capturePayload,
            impromptuReviewPayload: $impromptuReviewPayload,
            peopleMode: $peopleMode,
            openWindow: openWindow
        ))
        .sheet(item: $capturePayload) { payload in
            PostMeetingCaptureView(
                payload: payload,
                onSave: {}
            )
        }
        .restoreOnUnlock(item: $capturePayload)
        .sheet(item: $impromptuReviewPayload) { payload in
            ImpromptuRecordingReviewView(payload: payload)
        }
        .restoreOnUnlock(item: $impromptuReviewPayload)
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
        .dismissOnLock(isPresented: $showCommandPalette)
        .overlay(alignment: .bottom) {
            UndoToastView()
        }
        .alert(
            "Mark as Deceased?",
            isPresented: Binding(
                get: { noteAnalysisCoordinator.deceasedCandidate != nil },
                set: { if !$0 { noteAnalysisCoordinator.dismissDeceasedCandidate() } }
            )
        ) {
            Button("Mark as Deceased", role: .destructive) {
                if let candidate = noteAnalysisCoordinator.deceasedCandidate {
                    noteAnalysisCoordinator.confirmDeceased(candidate)
                }
            }
            Button("Not Now", role: .cancel) {
                noteAnalysisCoordinator.dismissDeceasedCandidate()
            }
        } message: {
            if noteAnalysisCoordinator.deceasedCandidate != nil {
                Text("SAM detected that this contact may have passed away. Would you like to mark them as deceased? This will stop all coaching and outreach suggestions for this person.")
            }
        }
        .dismissOnLock(isPresented: Binding(
            get: { noteAnalysisCoordinator.deceasedCandidate != nil },
            set: { if !$0 { noteAnalysisCoordinator.dismissDeceasedCandidate() } }
        ))
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
        .onChange(of: sidebarSelection) { _, newValue in
            // Clear people-specific filters when navigating away from People
            if newValue != "people" {
                peopleSpecialFilters.removeAll()
                RelationshipGraphCoordinator.shared.pendingSuggestionPersonIDs.removeAll()
                RelationshipGraphCoordinator.shared.applyFilters()
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

    // MARK: - Event Section Toolbar

    private var eventSectionToolbar: some View {
        Picker("", selection: $eventSection) {
            ForEach(EventManagerView.EventSection.allCases, id: \.self) { section in
                Text(section.rawValue).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 220)
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

            NavigationLink(value: "events") {
                Label("Events", systemImage: "calendar.badge.clock")
            }

            NavigationLink(value: "transcription") {
                Label("Transcription", systemImage: "waveform.and.mic")
            }

            NavigationLink(value: "search") {
                Label("Search", systemImage: "magnifyingglass")
            }
        }
        .navigationTitle("SAM")
        .safeAreaInset(edge: .bottom) {
            MinionsView()
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

        case "people":
            if peopleMode == .graph {
                RelationshipGraphView()
            } else {
                peopleContactsView
            }

        case "business":
            BusinessDashboardView()

        case "grow":
            GrowDashboardView()

        case "events":
            EventManagerView(activeSection: $eventSection)

        case "transcription":
            TranscriptionSessionView()

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

    // MARK: - People Contacts View (List + Detail via HSplitView)

    @State private var peopleListWidth: CGFloat = 280

    private var peopleContactsView: some View {
        HStack(spacing: 0) {
            PeopleListView(selectedPersonID: $selectedPersonID, activeSpecialFilters: $peopleSpecialFilters)
                .frame(width: peopleListWidth)

            PeopleListDivider(listWidth: $peopleListWidth)

            Group {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

}

// MARK: - Draggable Split Divider

/// A thin vertical divider that can be dragged to resize the people list column.
/// Shows the standard macOS horizontal-resize cursor on hover.
private struct PeopleListDivider: View {
    @Binding var listWidth: CGFloat

    private let minWidth: CGFloat = 200
    private let maxWidth: CGFloat = 500

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .padding(.horizontal, 3)
            .frame(width: 7) // Wider hit target
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let newWidth = listWidth + value.translation.width
                        listWidth = min(max(newWidth, minWidth), maxWidth)
                    }
            )
    }
}

// MARK: - Notification Handlers

private struct AppShellNotificationHandlers: ViewModifier {
    @Binding var sidebarSelection: String
    @Binding var selectedPersonID: UUID?
    @Binding var capturePayload: CapturePayload?
    @Binding var impromptuReviewPayload: ImpromptuReviewPayload?
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
                if let payload = notification.userInfo?["payload"] as? CapturePayload {
                    capturePayload = payload
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .samOpenImpromptuReview)) { notification in
                if let payload = notification.userInfo?["payload"] as? ImpromptuReviewPayload {
                    impromptuReviewPayload = payload
                }
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
            .onReceive(NotificationCenter.default.publisher(for: .samOpenPromptLab)) { _ in
                openWindow(id: "prompt-lab")
            }
            .onReceive(NotificationCenter.default.publisher(for: .samOpenGuide)) { _ in
                openWindow(id: "guide")
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
