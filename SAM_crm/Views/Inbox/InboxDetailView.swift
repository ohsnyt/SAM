//
//  InboxDetailView.swift
//  SAM_crm
//

import SwiftUI

struct InboxDetailView: View {
    let store: MockEvidenceRuntimeStore
    let evidenceID: UUID?

    @State private var showFullText: Bool = true

    // Optional: for quick linking actions, we access these stores.
    private let peopleStore = MockPeopleRuntimeStore.shared
    private let contextStore = MockContextRuntimeStore.shared

    var body: some View {
        if let item = store.item(id: evidenceID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {

                    header(item)

                    if showFullText, let body = item.bodyText, !body.isEmpty {
                        GroupBox("Evidence") {
                            Text(body)
                                .textSelection(.enabled)
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                        }
                    } else {
                        GroupBox("Evidence") {
                            Text(item.snippet)
                                .textSelection(.enabled)
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                        }
                    }

                    if !item.signals.isEmpty {
                        GroupBox("Signals") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(item.signals) { s in
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: s.kind.systemImage)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 18)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(s.kind.title)
                                                .font(.headline)

                                            Text(s.reason)
                                                .font(.callout)
                                                .foregroundStyle(.secondary)

                                            Text("Confidence: \(Int((s.confidence * 100).rounded()))%")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }

                                        Spacer()
                                    }
                                }
                            }
                            .padding(.vertical, 6)
                        }
                    }

                    GroupBox("Suggested Links") {
                        if item.proposedLinks.isEmpty {
                            Text("No suggestions yet. Attach this evidence to a person or context manually.")
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                suggestedLinksSection(item)
                            }
                            .padding(.vertical, 6)
                        }
                    }

                    GroupBox("Confirmed Links") {
                        confirmedLinksSection(item)
                            .padding(.vertical, 6)
                    }

                    actionsRow(item)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: 760, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .navigationTitle("Inbox")
            .toolbar {
                ToolbarItemGroup {
                    Toggle(isOn: $showFullText) {
                        Image(systemName: showFullText ? "doc.text" : "text.quote")
                    }
                    .toggleStyle(.button)
                    .help(showFullText ? "Show full text" : "Show snippet")

                    Button {
                        store.markDone(item.id)
                    } label: {
                        Label("Mark Done", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.glass)
                    .help("Mark this evidence as reviewed")
                    .disabled(item.state == .done)
                }
            }
        } else {
            ContentUnavailableView(
                "Select an item",
                systemImage: "tray",
                description: Text("Choose an evidence item from the Inbox list.")
            )
            .padding()
        }
    }

    private func header(_ item: EvidenceItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.title)
                    .font(.title2)
                    .bold()

                Spacer()

                Text(formatDate(item.occurredAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Label(item.source.title, systemImage: item.source.systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if item.state == .needsReview {
                    Label("Needs Review", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Done", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func suggestedLinksSection(_ item: EvidenceItem) -> some View {
        let people = item.proposedLinks.filter { $0.target == .person }.sorted { $0.confidence > $1.confidence }
        let contexts = item.proposedLinks.filter { $0.target == .context }.sorted { $0.confidence > $1.confidence }

        if !people.isEmpty {
            Text("People")
                .font(.headline)

            ForEach(people) { link in
                SuggestedLinkRow(
                    title: link.displayName,
                    subtitle: link.secondaryLine,
                    confidence: link.confidence,
                    reason: link.reason,
                    systemImage: "person.crop.circle",
                    primaryActionTitle: "Attach"
                ) {
                    store.linkToPerson(evidenceID: item.id, personID: link.targetID)
                }
            }
        }

        if !contexts.isEmpty {
            if !people.isEmpty { Divider().padding(.vertical, 6) }

            Text("Contexts")
                .font(.headline)

            ForEach(contexts) { link in
                SuggestedLinkRow(
                    title: link.displayName,
                    subtitle: link.secondaryLine,
                    confidence: link.confidence,
                    reason: link.reason,
                    systemImage: "square.3.layers.3d",
                    primaryActionTitle: "Attach"
                ) {
                    store.linkToContext(evidenceID: item.id, contextID: link.targetID)
                }
            }
        }
    }

    @ViewBuilder
    private func confirmedLinksSection(_ item: EvidenceItem) -> some View {
        if item.linkedPeople.isEmpty && item.linkedContexts.isEmpty {
            Text("Nothing attached yet.")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if !item.linkedPeople.isEmpty {
                    Text("People")
                        .font(.headline)

                    ForEach(item.linkedPeople, id: \.self) { pid in
                        let name = peopleStore.byID[pid]?.displayName ?? "Unknown Person"
                        Label(name, systemImage: "person.crop.circle")
                            .foregroundStyle(.primary)
                    }
                }

                if !item.linkedContexts.isEmpty {
                    if !item.linkedPeople.isEmpty { Divider().padding(.vertical, 6) }

                    Text("Contexts")
                        .font(.headline)

                    ForEach(item.linkedContexts, id: \.self) { cid in
                        let name = contextStore.byID[cid]?.name ?? "Unknown Context"
                        Label(name, systemImage: "square.3.layers.3d")
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
    }

    private func actionsRow(_ item: EvidenceItem) -> some View {
        HStack(spacing: 10) {
            Button {
                store.markDone(item.id)
            } label: {
                Label("Mark Done", systemImage: "checkmark.circle")
            }
            .buttonStyle(.glass)
            .disabled(item.state == .done)

            Button {
                store.reopen(item.id)
            } label: {
                Label("Reopen", systemImage: "arrow.uturn.backward.circle")
            }
            .buttonStyle(.glass)
            .disabled(item.state == .needsReview)

            Spacer()
        }
        .padding(.top, 4)
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }
}

private struct SuggestedLinkRow: View {
    let title: String
    let subtitle: String?
    let confidence: Double
    let reason: String
    let systemImage: String
    let primaryActionTitle: String
    let onPrimary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)

                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    Text("Confidence: \(Int((confidence * 100).rounded()))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(primaryActionTitle) {
                    onPrimary()
                }
                .buttonStyle(.glass)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
        )
    }
}
