//
//  InboxHost.swift
//  SAM_crm
//
//  Evidence Inbox: triage + link + explainable signals.
//

import SwiftUI
import SwiftData

struct InboxHost: View {
    @State private var repo = EvidenceRepository.shared
    @State private var selectedEvidenceID: UUID? = nil
    @State private var searchText: String = ""

    @Query private var allPeople: [SamPerson]

    private var notePeopleItems: [AddNoteForPeopleView.PersonItem] {
        allPeople.map { AddNoteForPeopleView.PersonItem(id: $0.id, displayName: $0.displayName) }
    }

    var body: some View {
        // IMPORTANT:
        // Do not nest NavigationSplitView / NavigationStack inside AppShellView's detail column.
        // Nested navigation containers can create an apparent "left padding" when the sidebar is shown.
        // Instead, render a simple two-pane split view inside the detail column.
#if os(macOS)
        HSplitView {
            InboxListView(selectedEvidenceID: $selectedEvidenceID, searchText: $searchText)
                .frame(minWidth: 280, idealWidth: 340, maxWidth: 460)

            InboxDetailView(repo: repo, evidenceID: selectedEvidenceID)
                .frame(minWidth: 420)
        }
        // Attach .searchable to the HSplitView so macOS owns the search bar
        // at a stable layout level.  Putting it on the List inside the split
        // caused a phantom padding region to appear / disappear on selection
        // changes because HSplitView is not a navigation container and cannot
        // properly manage the search-bar lifecycle.
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search inbox")
        .navigationTitle("Inbox")
        .addNoteToolbar(people: notePeopleItems, container: SAMModelContainer.shared)
        .task {
            if selectedEvidenceID == nil {
                // Yield to ensure app-wide container configuration completes before first fetch
                await Task.yield()
                let pair = repo.newestIDs()
                selectedEvidenceID = pair.needs ?? pair.done
            }
        }
#else
        // iOS: keep a single navigation context (AppShellView will likely host this inside a NavigationStack).
        // Using a local NavigationStack here is acceptable on iOS where we don't have the same split-sidebar behavior.
        NavigationStack {
            InboxListView(selectedEvidenceID: $selectedEvidenceID, searchText: $searchText)
                .navigationTitle("Inbox")
                .searchable(text: $searchText, placement: .toolbar, prompt: "Search inbox")
                .addNoteToolbar(people: notePeopleItems, container: SAMModelContainer.shared)
                .navigationDestination(for: UUID.self) { id in
                    InboxDetailView(repo: repo, evidenceID: id)
                }
        }
        .task {
            if selectedEvidenceID == nil {
                // Yield to ensure app-wide container configuration completes before first fetch
                await Task.yield()
                let pair = repo.newestIDs()
                selectedEvidenceID = pair.needs ?? pair.done
            }
        }
#endif
    }
}

