//
//  InboxHost.swift
//  SAM_crm
//
//  Evidence Inbox: triage + link + explainable signals.
//

import SwiftUI

struct InboxHost: View {
    @State private var store = MockEvidenceRuntimeStore.shared
    @State private var selectedEvidenceID: UUID? = nil

    var body: some View {
        // IMPORTANT:
        // Do not nest NavigationSplitView / NavigationStack inside AppShellView’s detail column.
        // Nested navigation containers can create an apparent “left padding” when the sidebar is shown.
        // Instead, render a simple two-pane split view inside the detail column.
#if os(macOS)
        HSplitView {
            InboxListView(store: store, selectedEvidenceID: $selectedEvidenceID)
                .frame(minWidth: 280, idealWidth: 340, maxWidth: 460)

            InboxDetailView(store: store, evidenceID: selectedEvidenceID)
                .frame(minWidth: 420)
        }
        .navigationTitle("Inbox")
        .task {
            // Default selection: newest needs-review item, else newest done item.
            if selectedEvidenceID == nil {
                selectedEvidenceID = store.needsReview.first?.id ?? store.done.first?.id
            }
        }
#else
        // iOS: keep a single navigation context (AppShellView will likely host this inside a NavigationStack).
        // Using a local NavigationStack here is acceptable on iOS where we don’t have the same split-sidebar behavior.
        NavigationStack {
            InboxListView(store: store, selectedEvidenceID: $selectedEvidenceID)
                .navigationTitle("Inbox")
                .navigationDestination(for: UUID.self) { id in
                    InboxDetailView(store: store, evidenceID: id)
                }
        }
        .task {
            if selectedEvidenceID == nil {
                selectedEvidenceID = store.needsReview.first?.id ?? store.done.first?.id
            }
        }
#endif
    }
}
