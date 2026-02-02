//
//  InboxListView.swift
//  SAM_crm
//

import SwiftUI

struct InboxListView: View {
    let store: MockEvidenceRuntimeStore
    @Binding var selectedEvidenceID: UUID?

    @State private var searchText: String = ""

    var body: some View {
        List(selection: $selectedEvidenceID) {
            if filteredNeedsReview.isEmpty && filteredDone.isEmpty {
                ContentUnavailableView(
                    "No evidence",
                    systemImage: "tray",
                    description: Text("As SAM observes Mail, Calendar, and Zoom, items will appear here for review.")
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                if !filteredNeedsReview.isEmpty {
                    Section("Needs Review") {
                        ForEach(filteredNeedsReview) { item in
                            InboxRow(item: item)
                                .tag(item.id as UUID?)
                        }
                    }
                }

                if !filteredDone.isEmpty {
                    Section("Done") {
                        ForEach(filteredDone) { item in
                            InboxRow(item: item)
                                .tag(item.id as UUID?)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .listSectionSeparator(.hidden)
        .scrollContentBackground(.hidden)
        .background(listBackground)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search inbox")
        .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 520)
    }

    private var filteredNeedsReview: [EvidenceItem] {
        filter(store.needsReview)
    }

    private var filteredDone: [EvidenceItem] {
        filter(store.done)
    }

    private func filter(_ items: [EvidenceItem]) -> [EvidenceItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter { e in
            e.title.lowercased().contains(q) ||
            e.snippet.lowercased().contains(q) ||
            e.source.title.lowercased().contains(q)
        }
    }

    private var listBackground: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            Rectangle()
                .fill(.regularMaterial)
                .opacity(0.25)
        }
    }
}

private struct InboxRow: View {
    let item: EvidenceItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.source.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .lineLimit(1)

                Text(item.snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Label(item.source.title, systemImage: item.source.systemImage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if !item.signals.isEmpty {
                        Text("\(item.signals.count) signal\(item.signals.count == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if item.state == .needsReview {
                        Text("Review")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Text(relativeWhen(item.occurredAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 6)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .contentShape(Rectangle())
        .contextMenu {
            if item.state == .needsReview {
                Button("Mark Done") {
                    MockEvidenceRuntimeStore.shared.markDone(item.id)
                }
            } else {
                Button("Reopen") {
                    MockEvidenceRuntimeStore.shared.reopen(item.id)
                }
            }
        }
    }

    private func relativeWhen(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
