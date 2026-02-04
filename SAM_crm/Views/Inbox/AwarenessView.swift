/// AwarenessView.swift
///
import SwiftUI

/// Home screen: a calm, prioritized awareness feed.
/// Works with any insight type that conforms to InsightDisplayable.
struct AwarenessView<I: InsightDisplayable>: View {

    let insights: [I]
    /// Optional tap action for drill-in (e.g. “Why?” evidence).
    var onInsightTapped: ((I) -> Void)? = nil

    @State private var searchText: String = ""
    @State private var selection: InsightSelection? = nil

    var body: some View {
        List(selection: $selection) {

            if filteredInsights.isEmpty {
                emptyState
            } else {
                if !needsAttention.isEmpty {
                    Section("Needs Attention") { insightCards(needsAttention) }
                }

                if !followUps.isEmpty {
                    Section("Suggested Follow-Ups") { insightCards(followUps) }
                }

                if !opportunities.isEmpty {
                    Section("Opportunities") { insightCards(opportunities) }
                }
            }
        }
        .listStyle(.inset)
        .listSectionSeparator(.hidden)
        .scrollContentBackground(.hidden)
        .background(listBackground)
        .navigationTitle("Awareness")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search insights")
        .toolbar {
            ToolbarItemGroup {
                Button { } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.glass)
                    .help("Refresh")
                    .keyboardShortcut("r", modifiers: [.command])

                Button { searchText = "" } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.glass)
                    .help("Clear Search")
                    .disabled(searchText.isEmpty)
            }
        }
    }
}

// MARK: - Filtering & Sections

private extension AwarenessView {

    var filteredInsights: [I] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return insights }

        let q = trimmed.lowercased()
        return insights.filter { item in
            item.message.lowercased().contains(q) ||
            item.typeDisplayName.lowercased().contains(q)
        }
    }

    var needsAttention: [I] {
        filteredInsights
            .filter { $0.kind == .consentMissing || $0.kind == .complianceWarning }
            .sorted(by: sortByPriorityThenConfidence)
    }

    var followUps: [I] {
        filteredInsights
            .filter { $0.kind == .followUp || $0.kind == .relationshipAtRisk }
            .sorted(by: sortByPriorityThenConfidence)
    }

    var opportunities: [I] {
        filteredInsights
            .filter { $0.kind == .opportunity }
            .sorted(by: sortByPriorityThenConfidence)
    }

    func sortByPriorityThenConfidence(_ a: I, _ b: I) -> Bool {
        let pa = priority(for: a.kind)
        let pb = priority(for: b.kind)
        if pa != pb { return pa < pb }
        return a.confidence > b.confidence
    }

    func priority(for kind: InsightKind) -> Int {
        switch kind {
        case .complianceWarning:   return 0
        case .consentMissing:      return 1
        case .relationshipAtRisk:  return 2
        case .followUp:            return 3
        case .opportunity:         return 4
        }
    }
}

// MARK: - Rendering

private extension AwarenessView {

    @ViewBuilder
    func insightCards(_ items: [I]) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { pair in
            let insight = pair.element

            let card = InsightCardView(insight: insight)
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .padding(.vertical, 2)

            if let onInsightTapped {
                Button {
                    onInsightTapped(insight)
                } label: {
                    card
                }
                .buttonStyle(.plain)           // keep card visuals
                .contentShape(Rectangle())     // ensure full-row click target
                .contextMenu {
                    Button("Why?") { onInsightTapped(insight) }
                }
            } else {
                card
            }
        }
    }

    var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No insights right now")
                .font(.headline)

            Text("As SAM observes interactions and obligations, suggestions and reviews will appear here.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("Tip: Start by selecting a person and reviewing contexts.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
    }

    var listBackground: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            Rectangle().fill(.regularMaterial).opacity(0.25)
        }
    }
}

// MARK: - Selection placeholder

private struct InsightSelection: Hashable {
    let id = UUID()
}
