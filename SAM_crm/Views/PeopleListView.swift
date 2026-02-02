//
//  PeopleListView.swift
//  SAM_crm
//
//  Created by David Snyder on 1/31/26.
//

import SwiftUI

struct PeopleListView: View {
    @Binding var selectedPersonID: UUID?
    @AppStorage("sam.people.searchText") private var searchText: String = ""
    
    private let people = MockPeopleStore.listItems
    
    var body: some View {
        List(filteredPeople, selection: $selectedPersonID) { person in
            PersonRow(person: person)
                .tag(person.id as UUID?)
        }
        .navigationTitle("People")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search people")
        .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        .task { autoSelectIfNeeded() }
    }
    
    private var filteredPeople: [PersonListItemModel] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return people }
        return people.filter {
            $0.displayName.lowercased().contains(q) ||
            $0.roleBadges.joined(separator: " ").lowercased().contains(q)
        }
    }
    
    private func autoSelectIfNeeded() {
        guard selectedPersonID == nil else { return }
        
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return }
        
        let pool = filteredPeople.isEmpty ? people : filteredPeople
        guard let best = pool.max(by: { score($0) < score($1) }) else { return }
        
        selectedPersonID = score(best) > 0 ? best.id : pool.first?.id
    }
    
    private func score(_ p: PersonListItemModel) -> Int {
        p.consentAlertsCount * 3 + p.reviewAlertsCount * 2
    }
}
