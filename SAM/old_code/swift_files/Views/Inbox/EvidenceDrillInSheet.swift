//
//  EvidenceDrillInSheet.swift
//  SAM_crm
//
//  Created by David Snyder on 2/2/26.
//

import SwiftUI
import Foundation

/// A trust-first drill-in: show the evidence items backing an Insight.
/// macOS: two-pane split (list + detail). iOS: list -> detail push (no nested split view).
struct EvidenceDrillInSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let evidenceIDs: [UUID]

    // SwiftData-backed evidence repository
    private let evidenceStore = EvidenceRepository.shared

    @State private var selectedEvidenceID: UUID?

    /// Fetch each requested ID individually and sort newest-first.
    /// The set is small (it's the evidence backing a single insight card)
    /// so the per-item round-trip is fine.
    private var evidenceItems: [SamEvidenceItem] {
        evidenceIDs.compactMap { try? evidenceStore.item(id: $0) }
            .sorted { $0.occurredAt > $1.occurredAt }
    }

    private func item(for id: UUID) -> SamEvidenceItem? {
        try? evidenceStore.item(id: id)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

#if os(macOS)
            HSplitView {
                evidenceList
                    .frame(minWidth: 320, idealWidth: 360)

                evidenceDetail
                    .frame(minWidth: 420)
            }
#else
            NavigationStack {
                List(evidenceItems, selection: $selectedEvidenceID) { item in
                    EvidenceRow(item: item)
                        .tag(item.id as UUID?)
                }
                .navigationTitle("Evidence")
                .navigationDestination(for: UUID.self) { id in
                    EvidenceDetailPane(item: item(for: id))
                }
            }
#endif
        }
        .frame(minWidth: 860, minHeight: 520) // macOS friendly
        .onAppear {
            if selectedEvidenceID == nil {
                selectedEvidenceID = evidenceItems.first?.id
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Why SAM suggested this")
                    .font(.headline)

                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

#if os(macOS)
    private var evidenceList: some View {
        List(evidenceItems, selection: $selectedEvidenceID) { item in
            EvidenceRow(item: item)
                .tag(item.id as UUID?)
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var evidenceDetail: some View {
        EvidenceDetailPane(item: selectedEvidenceID.flatMap { item(for: $0) })
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
    }
#endif
}

private struct EvidenceRow: View {
    let item: SamEvidenceItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.source.systemImage)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .lineLimit(1)

                Text(item.snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text(item.source.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text(item.occurredAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if !item.signals.isEmpty {
                Text("\(item.signals.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                    )
            }
        }
        .padding(.vertical, 2)
    }
}

private struct EvidenceDetailPane: View {
    let item: SamEvidenceItem?

    var body: some View {
        if let item {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: item.source.systemImage)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.title3)
                                .bold()
                            Text(item.occurredAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }

                    if !item.signals.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Detected signals")
                                .font(.headline)

                            ForEach(item.signals) { s in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: s.kind.systemImage)
                                        .foregroundStyle(.secondary)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(s.kind.title)
                                        Text("Confidence: \(Int(s.confidence * 100))%")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if !s.reason.isEmpty {
                                            Text(s.reason)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Evidence")
                            .font(.headline)

                        Text((item.bodyText?.isEmpty == false) ? (item.bodyText ?? "") : item.snippet)
                            .textSelection(.enabled)
                            .font(.body)
                            .foregroundStyle(.primary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: 760, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            ContentUnavailableView(
                "Select an evidence item",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Choose an item on the left to see details.")
            )
            .padding()
        }
    }
}
