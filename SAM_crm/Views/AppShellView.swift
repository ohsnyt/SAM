//
//  AppShellView.swift
//  SAM_crm
//
//  Created by David Snyder on 1/31/26.
//

import SwiftUI
import EventKit
import Contacts

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
                        PersonDetailHost(selectedPersonID: UUID(uuidString: selectedPersonIDRaw))

                    case .contexts:
                        ContextDetailRouter(selectedContextID: UUID(uuidString: selectedContextIDRaw))

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
                    // Use the environment action — it is the reliable,
                    // supported way to bring up the Settings window from
                    // any SwiftUI view, including sheets.
                    openSettings()
                    dismiss()
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
    @State private var store = MockContextRuntimeStore.shared

    var body: some View {
        if let id = selectedContextID, let ctx = store.byID[id] {
            ContextDetailView(context: ctx)
        } else {
            ContextDetailPlaceholderView()
        }
    }
}

enum MockContextStore {
    static let all: [ContextDetailModel] = [
        MockContexts.smithHousehold
        // Add more ContextDetailModel here
    ]

    static let byID: [UUID: ContextDetailModel] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static let listItems: [ContextListItemModel] = all.map { ctx in
        ContextListItemModel(
            id: ctx.id,
            name: ctx.name,
            subtitle: ctx.listSubtitle,
            kind: ctx.kind,
            consentCount: ctx.alerts.consentCount,
            reviewCount: ctx.alerts.reviewCount,
            followUpCount: ctx.alerts.followUpCount
        )
    }
}

