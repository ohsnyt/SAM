//
//  InboxListView.swift
//  SAM_crm
//

import SwiftUI
import SwiftData

struct InboxListView: View {
    @Binding var selectedEvidenceID: UUID?

    /// Search text is owned by InboxHost and applied as .searchable there
    /// (on the HSplitView on macOS, on the NavigationStack on iOS).  We
    /// receive it as a binding so the filtering logic stays local to the
    /// list without this view needing to know where the search bar lives.
    @Binding var searchText: String

    // ── SwiftData query ───────────────────────────────────────────────
    // Single unfiltered query; state partitioning is done in-memory.
    // #Predicate cannot capture RawRepresentable enum cases or traverse
    // .rawValue as a key path, so filtering on EvidenceTriageState inside
    // a static @Query is not possible.  The inbox dataset is small enough
    // that in-memory partitioning is the right tradeoff.
    @Query(sort: \SamEvidenceItem.occurredAt, order: .reverse)
    private var allItems: [SamEvidenceItem]

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
        .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 520)
    }

    // ── Partitioned + filtered views ──────────────────────────────────

    private var needsReviewItems: [SamEvidenceItem] {
        allItems.filter { $0.state == .needsReview }
    }

    private var doneItems: [SamEvidenceItem] {
        allItems.filter { $0.state == .done }
    }

    private var filteredNeedsReview: [SamEvidenceItem] {
        filter(needsReviewItems)
    }

    private var filteredDone: [SamEvidenceItem] {
        filter(doneItems)
    }

    private func filter(_ items: [SamEvidenceItem]) -> [SamEvidenceItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter { e in
            e.title.lowercased().contains(q) ||
            e.snippet.lowercased().contains(q) ||
            e.source.title.lowercased().contains(q)
        }
    }

    // ── Background ────────────────────────────────────────────────────

    private var listBackground: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            Rectangle()
                .fill(.regularMaterial)
                .opacity(0.25)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - InboxRow
// ─────────────────────────────────────────────────────────────────────
private struct InboxRow: View {
    let item: SamEvidenceItem

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

                    if item.state == EvidenceTriageState.needsReview {
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
            if item.state == EvidenceTriageState.needsReview {
                Button("Mark Done") {
                    try? EvidenceRepository.shared.markDone(item.id)
                }
            } else {
                Button("Reopen") {
                    try? EvidenceRepository.shared.reopen(item.id)
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
