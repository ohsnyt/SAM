//
//  AppShellView.swift
//  SAM_crm
//
//  Created by David Snyder on 1/31/26.
//

import SwiftUI
import EventKit
import Contacts
import SwiftData

// MARK: - Badge Counts

/// Observable object that provides badge counts for sidebar items.
/// Queries SwiftData for real-time counts.
@Observable
final class SidebarBadgeCounter {
    var needsAttentionCount: Int = 0
    var inboxNeedsReviewCount: Int = 0
    var unlinkedPeopleCount: Int = 0  // Phase 1.2: Count of people without contactIdentifier
    
    func refresh(modelContext: ModelContext) {
        // Count evidence needing review
        let evidenceDescriptor = FetchDescriptor<SamEvidenceItem>(
            predicate: #Predicate { $0.stateRawValue == "needsReview" }
        )
        inboxNeedsReviewCount = (try? modelContext.fetchCount(evidenceDescriptor)) ?? 0
        
        // Count people and contexts with alerts (needs attention)
        let peopleDescriptor = FetchDescriptor<SamPerson>(
            predicate: #Predicate { $0.consentAlertsCount > 0 || $0.reviewAlertsCount > 0 }
        )
        let contextsDescriptor = FetchDescriptor<SamContext>(
            predicate: #Predicate { $0.consentAlertCount > 0 || $0.reviewAlertCount > 0 || $0.followUpAlertCount > 0 }
        )
        
        let peopleCount = (try? modelContext.fetchCount(peopleDescriptor)) ?? 0
        let contextsCount = (try? modelContext.fetchCount(contextsDescriptor)) ?? 0
        
        needsAttentionCount = peopleCount + contextsCount
        
        // Phase 1.2: Count unlinked people (no contactIdentifier)
        let unlinkedDescriptor = FetchDescriptor<SamPerson>(
            predicate: #Predicate { $0.contactIdentifier == nil || $0.contactIdentifier == "" }
        )
        unlinkedPeopleCount = (try? modelContext.fetchCount(unlinkedDescriptor)) ?? 0
    }
}

// MARK: - Permission Checker

private enum PermissionChecker {
    static func calendarAccessGranted() -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, iOS 17.0, *) {
            return status == .fullAccess || status == .writeOnly
        } else {
            return status == .authorized
        }
    }

    static func contactsAccessGranted() -> Bool {
        return CNContactStore.authorizationStatus(for: .contacts) == .authorized
    }

    static func allRequiredGranted() -> Bool {
        calendarAccessGranted() && contactsAccessGranted()
    }
}

struct AppShellView: View {
    // Persist sidebar selection
    @AppStorage("sam.sidebar.selection")
    private var selectionRaw: String = SidebarItem.awareness.rawValue

    // Persist last selections
    @AppStorage("sam.people.selectedPersonID") 
    private var selectedPersonIDRaw: String = ""
    @AppStorage("sam.contexts.selectedContextID")
    private var selectedContextIDRaw: String = ""

    /// Drives the sheet.  Evaluated once in `.task`; never re-shown after dismissal.
    @State private var showPermissionNudge: Bool = false
    
    /// Badge counter for sidebar items
    @State private var badgeCounter = SidebarBadgeCounter()
    
    /// Keyboard shortcuts palette
    @State private var showKeyboardShortcuts: Bool = false
    
    /// Phase B Testing: Show contacts test view
    #if DEBUG
    @State private var showContactsTest: Bool = false
    #endif
    
    @Environment(\.modelContext) private var modelContext

    private var selectionBinding: Binding<SidebarItem> {
        Binding(
            get: { SidebarItem(rawValue: selectionRaw) ?? .awareness },
            set: { selectionRaw = $0.rawValue }
        )
    }

    private var selectedPersonIDBinding: Binding<UUID?> {
        Binding(
            get: { UUID(uuidString: selectedPersonIDRaw) },
            set: { selectedPersonIDRaw = $0?.uuidString ?? "" }
        )
    }

    private var selectedContextIDBinding: Binding<UUID?> {
        Binding(
            get: { UUID(uuidString: selectedContextIDRaw) },
            set: { selectedContextIDRaw = $0?.uuidString ?? "" }
        )
    }

    var body: some View {
        let selection = SidebarItem(rawValue: selectionRaw) ?? .awareness

        // Wrap in a ZStack so that .task and .sheet are anchored to a single
        // concrete layout container rather than a bare Group (which does not
        // reliably propagate lifecycle modifiers on macOS).
        ZStack {
            if selection == .awareness || selection == .inbox {
                // 2-column: Sidebar + Detail (no middle column exists)
                NavigationSplitView {
                    sidebar
                } detail: {
                    switch selection {
                    case .awareness:
                        AwarenessHost()

                    case .inbox:
                        InboxHost()
                    case .people, .contexts:
                        // unreachable in this branch
                        AwarenessHost()
                    }
                }
            } else {
                // 3-column: Sidebar + Content + Detail
                NavigationSplitView {
                    sidebar
                } content: {
                    switch selection {
                    case .people:
                        PeopleListView(selectedPersonID: selectedPersonIDBinding)
                    case .contexts:
                        ContextListView(selectedContextID: selectedContextIDBinding)
                    case .awareness, .inbox:
                        EmptyView()
                    }
                } detail: {
                    switch selection {
                    case .people:
                        PersonDetailHost(selectedPersonID: selectedPersonIDBinding.wrappedValue)

                    case .contexts:
                        ContextDetailRouter(selectedContextID: selectedContextIDBinding.wrappedValue)

                    case .awareness:
                        AwarenessHost()

                    case .inbox:
                        InboxHost()
                    }
                }
            }
        }
        // ── LLM status indicator ──────────────────────────────────────────
        .safeAreaInset(edge: .bottom) {
            LLMStatusBar()
        }
        // ── one-time permission nudge ────────────────────────────────────
        .sheet(isPresented: $showPermissionNudge) {
            PermissionNudgeSheet()
        }
        // ── keyboard shortcuts palette ───────────────────────────────────
        .sheet(isPresented: $showKeyboardShortcuts) {
            KeyboardShortcutsView()
        }
        #if DEBUG
        .sheet(isPresented: $showContactsTest) {
            ContactsTestView()
                .frame(minWidth: 600, minHeight: 700)
        }
        #endif
        // ── focused values for app commands ──────────────────────────────
        .focusedSceneValue(\.showKeyboardShortcuts, $showKeyboardShortcuts)
        .focusedSceneValue(\.sidebarSelection, $selectionRaw)
        .task {
            // Evaluate permissions once per startup. If missing, show the nudge.
            // We rely on `showPermissionNudge` (a @State) to ensure the sheet is not
            // re-presented multiple times within the same launch.
            let calendarOK = PermissionChecker.calendarAccessGranted()
            let contactsOK = PermissionChecker.contactsAccessGranted()
            if !calendarOK || !contactsOK {
                showPermissionNudge = true
            }
            
            // Auto-detect me card from Contacts if contacts access is granted
            if contactsOK {
                await MeCardManager.shared.autoDetectMeCard()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Refresh badge counts when app becomes active
            badgeCounter.refresh(modelContext: modelContext)
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            // Refresh badges when calendar changes (may affect evidence counts)
            Task {
                try? await Task.sleep(for: .seconds(2)) // Debounce
                badgeCounter.refresh(modelContext: modelContext)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .CNContactStoreDidChange)) { _ in
            // Refresh badges when contacts change
            Task {
                try? await Task.sleep(for: .seconds(2)) // Debounce
                badgeCounter.refresh(modelContext: modelContext)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .samNavigateToPerson)) { note in
            if let id = note.object as? UUID {
                selectionRaw = SidebarItem.people.rawValue
                selectedPersonIDRaw = id.uuidString
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .samNavigateToContext)) { note in
            if let id = note.object as? UUID {
                selectionRaw = SidebarItem.contexts.rawValue
                selectedContextIDRaw = id.uuidString
            }
        }
    }

    private var sidebar: some View {
        List(SidebarItem.allCases, selection: selectionBinding) { item in
            HStack {
                Label(item.rawValue, systemImage: item.systemImage)
                Spacer()
                if let badge = badgeCount(for: item), badge > 0 {
                    Text("\(badge)")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(badgeColor(for: item))
                        )
                        .help("\(badge) item\(badge == 1 ? "" : "s") need attention")
                }
            }
            .tag(item)
        }
        .listStyle(.sidebar)
        .navigationTitle("SAM")
        .navigationSplitViewColumnWidth(min: 120, ideal: 140, max: 200)
        #if DEBUG
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                DevelopmentMenu(showContactsTest: $showContactsTest)
            }
        }
        #endif
        .onChange(of: selectionRaw) { _, newValue in
            // Optional: clear stale selections when switching sections
            if newValue == SidebarItem.people.rawValue {
                selectedContextIDRaw = ""
            } else if newValue == SidebarItem.contexts.rawValue {
                selectedPersonIDRaw = ""
            }
        }
        .task {
            // Initial badge count
            badgeCounter.refresh(modelContext: modelContext)
            
            // Refresh badges periodically (every 30 seconds)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                badgeCounter.refresh(modelContext: modelContext)
            }
        }
    }
    
    /// Returns the badge count for a sidebar item, or nil if no badge should be shown
    private func badgeCount(for item: SidebarItem) -> Int? {
        switch item {
        case .awareness:
            return badgeCounter.needsAttentionCount > 0 ? badgeCounter.needsAttentionCount : nil
        case .inbox:
            return badgeCounter.inboxNeedsReviewCount > 0 ? badgeCounter.inboxNeedsReviewCount : nil
        case .people:
            // Phase 1.2: Show count of unlinked people (potential action item)
            return badgeCounter.unlinkedPeopleCount > 0 ? badgeCounter.unlinkedPeopleCount : nil
        case .contexts:
            return nil // No badge for contexts
        }
    }
    
    /// Returns the badge color for a sidebar item
    private func badgeColor(for item: SidebarItem) -> Color {
        switch item {
        case .awareness:
            return .orange // Needs attention = warning color
        case .inbox:
            return .blue // Inbox = informational color
        case .people:
            return .yellow // Unlinked = action needed color
        case .contexts:
            return .gray
        }
    }
}

// MARK: - LLM Status Bar

/// A collapsible status bar that shows when the LLM is analyzing content.
/// Displayed at the bottom of the window as a subtle indicator.
private struct LLMStatusBar: View {
    @State private var tracker = LLMStatusTracker.shared
    
    var body: some View {
        if tracker.isAnalyzing {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.8)
                
                Text(tracker.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.2), value: tracker.isAnalyzing)
        }
    }
}

// MARK: - Development Testing

#if DEBUG
/// Quick access to test views during development
private struct DevelopmentMenu: View {
    @Binding var showContactsTest: Bool
    
    var body: some View {
        Menu("Dev Tools", systemImage: "hammer") {
            Button("Test Contacts Service") {
                showContactsTest = true
            }
        }
        .help("Development testing tools")
    }
}
#endif

// MARK: - Permission Nudge

/// A one-time sheet that appears on first launch when Calendar and/or
/// Contacts permission has not yet been granted.  It tells the user exactly
/// what is missing and offers a single button that opens Settings directly
/// on the Permissions tab.  Dismissing the sheet without acting is fine —
/// the nudge will not reappear (the gate is in `AppShellView`).
private struct PermissionNudgeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    private let calendarOK: Bool = PermissionChecker.calendarAccessGranted()
    private let contactsOK: Bool = PermissionChecker.contactsAccessGranted()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // ── icon + headline ──────────────────────────────────────────
            HStack(spacing: 14) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)

                Text("A couple of permissions needed")
                    .font(.title2)
                    .bold()
            }

            // ── what's missing ───────────────────────────────────────────
            VStack(alignment: .leading, spacing: 10) {
                if !calendarOK {
                    permissionRow(
                        icon: "calendar",
                        title: "Calendar",
                        detail: "SAM needs Full Access to read events from the calendar you choose. Without it, no events will appear in your Inbox."
                    )
                }
                if !contactsOK {
                    permissionRow(
                        icon: "person.crop.circle",
                        title: "Contacts",
                        detail: "SAM uses Contacts to match event participants to real people. Without it, everyone shows up as \"Unknown\"."
                    )
                }
            }

            Divider()

            // ── reassurance ──────────────────────────────────────────────
            Text("SAM never modifies your Calendar or Contacts without your explicit action.")
                .font(.callout)
                .foregroundStyle(.secondary)

            // ── buttons ──────────────────────────────────────────────────
            HStack(spacing: 12) {
                Button("Open Settings") {
                    // Write the target tab before opening so SwiftUI's
                    // Settings scene lands on Permissions immediately.
                    SamSettingsView.selectedTab = 0

                    // Dismiss the sheet first, then open Settings on the
                    // next run-loop tick.  On macOS the sheet is a modal
                    // window; dismissing it while it is still key can
                    // race with the Settings scene appearing and cause the
                    // Settings window to land behind the main window or
                    // never become key at all.  A single-tick delay after
                    // dismiss gives AppKit time to resign the sheet and
                    // return key-window status to the main window cleanly
                    // before we ask SwiftUI to present the Settings scene.
                    dismiss()
                    DispatchQueue.main.async {
                        openSettings()
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("Not now") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(28)
        .frame(width: 440)
    }

    // ── helpers ──────────────────────────────────────────────────────────
    private func permissionRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ContextDetailRouter: View {
    let selectedContextID: UUID?

    @Query private var contexts: [SamContext]

    init(selectedContextID: UUID?) {
        self.selectedContextID = selectedContextID
        if let id = selectedContextID {
            _contexts = Query(filter: #Predicate<SamContext> { $0.id == id })
        } else {
            _contexts = Query()
        }
    }

    var body: some View {
        if let ctx = contexts.first {
            let peopleItems: [AddNoteForPeopleView.PersonItem] = ctx.participations.compactMap { part in
                guard let p = part.person else { return nil }
                return AddNoteForPeopleView.PersonItem(id: p.id, displayName: p.displayName)
            }

            ContextDetailView(context: mapToDetailModel(ctx))
                .addNoteToolbar(people: peopleItems, container: SAMModelContainer.shared)
        } else {
            ContextDetailPlaceholderView()
        }
    }

    private func mapToDetailModel(_ c: SamContext) -> ContextDetailModel {
        // Participants
        let participants: [ContextParticipantModel] = c.participations.compactMap { part in
            let name = part.person?.displayName ?? "Unknown Person"
            let pid  = part.person?.id ?? part.id
            return ContextParticipantModel(
                id: pid,
                displayName: name,
                roleBadges: part.roleBadges,
                icon: "person.crop.circle",
                isPrimary: part.isPrimary,
                note: part.note
            )
        }

        // Products (embedded cards)
        let products: [ContextProductModel] = c.productCards

        // Consent requirements (map from SwiftData model)
        let consents: [ConsentRequirementModel] = c.consentRequirements.map { req in
            ConsentRequirementModel(
                id: req.id,
                title: req.title,
                reason: req.reason,
                jurisdiction: req.jurisdiction,
                status: ConsentRequirementModel.Status(rawValue: req.status.rawValue) ?? .required
            )
        }

        // Interactions and insights
        let interactions: [InteractionModel] = c.recentInteractions
        let insights: [SamInsight] = c.insights

        return ContextDetailModel(
            id: c.id,
            name: c.name,
            kind: c.kind,
            alerts: ContextAlerts(
                consentCount: c.consentAlertCount,
                reviewCount: c.reviewAlertCount,
                followUpCount: c.followUpAlertCount
            ),
            participants: participants,
            products: products,
            consentRequirements: consents,
            recentInteractions: interactions,
            insights: insights
        )
    }
}

