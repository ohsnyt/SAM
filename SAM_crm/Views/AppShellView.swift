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
        // ── one-time permission nudge ────────────────────────────────────
        .sheet(isPresented: $showPermissionNudge) {
            PermissionNudgeSheet()
        }
        .task {
            // Evaluate permissions once per startup. If missing, show the nudge.
            // We rely on `showPermissionNudge` (a @State) to ensure the sheet is not
            // re-presented multiple times within the same launch.
            let calendarOK = PermissionChecker.calendarAccessGranted()
            let contactsOK = PermissionChecker.contactsAccessGranted()
            if !calendarOK || !contactsOK {
                showPermissionNudge = true
            }
        }
    }

    private var sidebar: some View {
        List(SidebarItem.allCases, selection: selectionBinding) { item in
            Label(item.rawValue, systemImage: item.systemImage)
                .tag(item)
        }
        .listStyle(.sidebar)
        .navigationTitle("SAM")
        .navigationSplitViewColumnWidth(min: 120, ideal: 140, max: 200)
        .onChange(of: selectionRaw) { _, newValue in
            // Optional: clear stale selections when switching sections
            if newValue == SidebarItem.people.rawValue {
                selectedContextIDRaw = ""
            } else if newValue == SidebarItem.contexts.rawValue {
                selectedPersonIDRaw = ""
            }
        }
    }
}

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
            ContextDetailView(context: mapToDetailModel(ctx))
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

        // Interactions and insights (embedded arrays — types match directly)
        let interactions: [InteractionModel] = c.recentInteractions
        let insights: [ContextInsight] = c.insights

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




