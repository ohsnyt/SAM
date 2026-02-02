//
//  ContextListView.swift
//  SAM_crm
//
//  Created by David Snyder on 1/31/26.
//

import SwiftUI

struct ContextListView: View {
    @Binding var selectedContextID: UUID?

    init(selectedContextID: Binding<UUID?>) {
        self._selectedContextID = selectedContextID
    }

    @AppStorage("sam.contexts.searchText") private var searchText: String = ""
    @AppStorage("sam.contexts.filter") private var filterRaw: String = ContextKindFilter.all.rawValue

    @State private var showingNewContextSheet = false
    private var store = MockContextRuntimeStore.shared
    
    private var contexts: [ContextListItemModel] { store.listItems }
    
    private var filter: ContextKindFilter {
        get { ContextKindFilter(rawValue: filterRaw) ?? .all }
        set { filterRaw = newValue.rawValue }
    }

    var body: some View {
        List(filteredContexts, selection: $selectedContextID) { ctx in
            ContextRow(context: ctx)
                .tag(ctx.id as UUID?)
        }
        .navigationTitle("Contexts")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search contexts")
        .toolbar {
            ToolbarItemGroup {
                Picker("Filter", selection: Binding(
                    get: { filter },
                    set: { filterRaw = $0.rawValue }
                )) {
                    ForEach(ContextKindFilter.allCases) { f in
                        Text(f.title).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .help("Filter contexts")

                Button {
                    showingNewContextSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.glass)
                .help("New Context")
                .keyboardShortcut("n", modifiers: [.command])
            }
        }
        .sheet(isPresented: $showingNewContextSheet) {
            NewContextSheet(
                existingContexts: store.listItems,
                onCreate: { draft in
                    let newID = store.add(draft)
                    selectedContextID = newID
                },
                onOpenExisting: { existingID in
                    selectedContextID = existingID
                }
            )
        }
        .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 460)
        .task { autoSelectIfNeeded() }
        .onChange(of: filterRaw) { _, _ in
            ensureSelectionIsVisible()
        }
        .onChange(of: searchText) { _, _ in
            ensureSelectionIsVisible()
        }
    }

    private var filteredContexts: [ContextListItemModel] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return contexts
            .filter { ctx in
                switch filter {
                case .all: return true
                case .household: return ctx.kind == .household
                case .business: return ctx.kind == .business
                case .recruiting: return ctx.kind == .recruiting
                }
            }
            .filter { ctx in
                guard !q.isEmpty else { return true }
                return ctx.name.lowercased().contains(q) ||
                       ctx.subtitle.lowercased().contains(q)
            }
            .sorted { a, b in
                if a.alertScore != b.alertScore { return a.alertScore > b.alertScore }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    private func autoSelectIfNeeded() {
        guard selectedContextID == nil else { return }

        // Don’t auto-select while the user is searching.
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return }

        guard let best = filteredContexts.first else { return }
        selectedContextID = best.id
    }

    private func ensureSelectionIsVisible() {
        // If nothing selected, let autoSelectIfNeeded decide (and it won't while searching).
        guard let current = selectedContextID else {
            autoSelectIfNeeded()
            return
        }

        // If current selection is still visible under current filter/search, keep it.
        if filteredContexts.contains(where: { $0.id == current }) {
            return
        }

        // Otherwise, clear selection while searching (don’t jump), or pick best when not searching.
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            selectedContextID = nil
            return
        }

        selectedContextID = filteredContexts.first?.id
    }
}

// MARK: - Row

private struct ContextRow: View {
    let context: ContextListItemModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: context.kind.icon)
                .foregroundStyle(.secondary)
                .font(.title3)

            VStack(alignment: .leading, spacing: 4) {
                Text(context.name)
                    .font(.body)

                Text(context.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if context.alertScore > 0 {
                    HStack(spacing: 8) {
                        if context.consentCount > 0 {
                            ContextPill(systemImage: "checkmark.seal", text: "\(context.consentCount)")
                        }
                        if context.reviewCount > 0 {
                            ContextPill(systemImage: "exclamationmark.triangle", text: "\(context.reviewCount)")
                        }
                        if context.followUpCount > 0 {
                            ContextPill(systemImage: "arrow.turn.down.right", text: "\(context.followUpCount)")
                        }
                    }
                    .padding(.top, 2)
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Open") { /* selection-driven */ }
            Button("Copy Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(context.name, forType: .string)
            }
        }
    }
}

private struct ContextPill: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
        )
    }
}

