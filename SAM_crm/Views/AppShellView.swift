//
//  AppShellView.swift
//  SAM_crm
//
//  Created by David Snyder on 1/31/26.
//

import SwiftUI

struct AppShellView: View {
    @State private var selection: SidebarItem = .awareness

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                NavigationLink(value: item) {
                    Label(item.rawValue, systemImage: item.systemImage)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("SAM")
        } detail: {
            DetailRouter(selection: selection)
        }
    }
}

private struct DetailRouter: View {
    let selection: SidebarItem

    var body: some View {
        switch selection {
        case .awareness:
            AwarenessHost()
        case .people:
            PeopleView()
        case .contexts:
            ContextsPlaceholderView()
        }
    }
}
