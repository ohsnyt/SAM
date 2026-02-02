//
//  AppShellView.swift
//  SAM_crm
//
//  Created by David Snyder on 1/31/26.
//

import SwiftUI

struct AppShellView: View {
    // Persist sidebar selection
    @AppStorage("sam.sidebar.selection") private var selectionRaw: String = SidebarItem.awareness.rawValue

    // Persist last selections
    @AppStorage("sam.people.selectedPersonID") private var selectedPersonIDRaw: String = ""
    @AppStorage("sam.contexts.selectedContextID") private var selectedContextIDRaw: String = ""

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

