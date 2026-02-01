//
//  PeopleView.swift
//  SAM_crm
//
//  Created by David Snyder on 1/31/26.
//

import SwiftUI

struct PeopleView: View {
    @State private var searchText: String = ""
    @State private var selectedPersonID: UUID?

    // Mock data for now (replace with SwiftData/Contacts later)
    private let people: [PersonRowModel] = MockPeopleData.allPeople

    private var filteredPeople: [PersonRowModel] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return people }
        return people.filter {
            $0.displayName.lowercased().contains(q) ||
            $0.roleBadges.joined(separator: " ").lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(filteredPeople, selection: $selectedPersonID) { person in
                PersonRow(person: person)
                    .tag(person.id as UUID?)
            }
            .listStyle(.sidebar)
            .navigationTitle("People")
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search people")
        } detail: {
            if let id = selectedPersonID,
               let person = people.first(where: { $0.id == id }) {
                PersonDetailView(person: person)
            } else {
                ContentUnavailableView(
                    "Select a person",
                    systemImage: "person.crop.circle",
                    description: Text("Choose someone from the list to view contexts, obligations, and recent interactions.")
                )
                .padding()
            }
        }
    }
}
