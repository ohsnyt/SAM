//
//  PersonDetailHost.swift
//  SAM_crm
//
//  Created by David Snyder on 1/31/26.
//

import SwiftUI

struct PersonDetailHost: View {
    let selectedPersonID: UUID?

    // NOTE: singleton stores (mock-first). These are reference types; no @State needed.
    private let peopleStore = MockPeopleRuntimeStore.shared
    private let contextStore = MockContextRuntimeStore.shared

    @State private var showingAddToContextSheet: Bool = false

    var body: some View {
        if let id = selectedPersonID,
           let person = peopleStore.byID[id] {

            PersonDetailView(person: person)
                .toolbar {
                    ToolbarItemGroup {
                        Button {
                            showingAddToContextSheet = true
                        } label: {
                            Label("Add to Context", systemImage: "person.badge.plus")
                        }
                        .buttonStyle(.glass)
                        .help("Add this person to a context")
                        .keyboardShortcut("k", modifiers: [.command])
                    }
                }
                .sheet(isPresented: $showingAddToContextSheet) {
                    AddPersonToContextSheet(
                        personID: person.id,
                        personName: person.displayName,
                        contexts: contextStore.listItems
                    ) { contextID, role in
                        // Look up the context list item for the person-side chip.
                        guard let ctxItem = contextStore.listItems.first(where: { $0.id == contextID }) else { return }

                        // 1) Add participant to the context.
                        contextStore.addParticipant(
                            contextID: contextID,
                            personID: person.id,
                            displayName: person.displayName,
                            role: role
                        )

                        // 2) Add context chip to the person.
                        peopleStore.addContext(
                            personID: person.id,
                            context: ctxItem
                        )
                    }
                }

        } else {
            ContentUnavailableView(
                "Select a person",
                systemImage: "person.crop.circle",
                description: Text("Choose someone from the People list.")
            )
            .padding()
        }
    }
}
