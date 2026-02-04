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
    @State private var showingNewPersonSheet = false
    
    private let store = MockPeopleRuntimeStore.shared  // ✅ plain property
    
    var body: some View {
        List(filteredPeople, selection: $selectedPersonID) { person in
            PersonRow(person: person)
                .tag(person.id as UUID?)
        }
        .navigationTitle("People")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search people")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showingNewPersonSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.glass)
                .help("New Person")
                .keyboardShortcut("n", modifiers: [.command])
            }
        }
        .sheet(isPresented: $showingNewPersonSheet) {
            NewPersonSheet(
                existingCandidates: store.all.map { p in
                    PersonDuplicateCandidate(
                        id: p.id,
                        displayName: p.displayName,
                        addressLine: nil,   // TODO: fill from Contacts later
                        phoneLine: nil      // TODO: fill from Contacts later
                    )
                },
                onCreate: { draft in
                    let newID = store.add(draft)
                    selectedPersonID = newID
                },
                onOpenExisting: { existingID in
                    selectedPersonID = existingID
                }
            )
        }
        .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 520)
        .task { autoSelectIfNeeded() }
        .onChange(of: searchText) { _, _ in
            // If the current selection is still visible under the new query, keep it.
            // Otherwise clear so the detail pane shows the placeholder until the user picks.
            if let current = selectedPersonID,
               !filteredPeople.contains(where: { $0.id == current }) {
                selectedPersonID = nil
            }
        }
    }
    
    private var filteredPeople: [PersonListItemModel] {
        let people = store.listItems  // reading observable state here triggers updates
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
        
        let pool = filteredPeople.isEmpty ? store.listItems : filteredPeople
        guard let best = pool.max(by: { score($0) < score($1) }) else { return }
        
        selectedPersonID = score(best) > 0 ? best.id : pool.first?.id
    }
    
    private func score(_ p: PersonListItemModel) -> Int {
        p.consentAlertsCount * 3 + p.reviewAlertsCount * 2
    }
}

