//
//  InboxListView.swift
//  SAM_crm
//
//  Created on February 11, 2026.
//  Phase F: Inbox (Evidence Triage UI)
//
//  List view for evidence items needing triage.
//  Displays items from EvidenceRepository with filter, search, and selection.
//

import SwiftUI
import SwiftData

struct InboxListView: View {

    // MARK: - Bindings

    @Binding var selectedEvidenceID: UUID?

    // MARK: - Dependencies

    @State private var repository = EvidenceRepository.shared
    @State private var importCoordinator = CalendarImportCoordinator.shared

    // MARK: - State

    @State private var items: [SamEvidenceItem] = []
    @State private var searchText = ""
    @State private var filter: EvidenceFilter = .needsReview
    @State private var isLoading = false
    @State private var errorMessage: String?

    // MARK: - Body

    var body: some View {
        Group {
            if isLoading && items.isEmpty {
                loadingView
            } else if let error = errorMessage {
                errorView(error)
            } else if items.isEmpty {
                emptyView
            } else {
                evidenceList
            }
        }
        .navigationTitle("Inbox")
        .searchable(text: $searchText, prompt: "Search evidence")
        .toolbar {
            ToolbarItemGroup {
                filterPicker

                importStatusBadge

                Button {
                    Task {
                        await importCoordinator.importNow()
                        await loadItems()
                    }
                } label: {
                    Label("Import Now", systemImage: "arrow.clockwise")
                }
                .disabled(importCoordinator.importStatus == .importing)
                .help("Import events from Calendar")
            }
        }
        .task {
            await loadItems()
        }
        .onChange(of: filter) { _, _ in
            Task {
                await loadItems()
            }
        }
        .onChange(of: searchText) { _, _ in
            Task {
                await loadItems()
            }
        }
    }

    // MARK: - Evidence List

    private var evidenceList: some View {
        List(selection: $selectedEvidenceID) {
            ForEach(items, id: \.id) { item in
                Button(action: {
                    selectedEvidenceID = item.id
                }) {
                    EvidenceRowView(item: item)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Filter Picker

    private var filterPicker: some View {
        Picker("Filter", selection: $filter) {
            ForEach(EvidenceFilter.allCases, id: \.self) { filterCase in
                Text(filterCase.label).tag(filterCase)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 250)
    }

    // MARK: - Empty State

    private var emptyView: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: "tray")
        } description: {
            Text(emptyDescription)
        } actions: {
            if filter == .needsReview {
                Button {
                    Task {
                        await importCoordinator.importNow()
                        await loadItems()
                    }
                } label: {
                    Text("Import Now")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var emptyTitle: String {
        if !searchText.isEmpty {
            return "No Results"
        }
        switch filter {
        case .needsReview: return "No Items to Review"
        case .reviewed: return "No Reviewed Items"
        case .all: return "No Evidence"
        }
    }

    private var emptyDescription: String {
        if !searchText.isEmpty {
            return "No evidence matches \"\(searchText)\""
        }
        switch filter {
        case .needsReview: return "Import calendar events to get started"
        case .reviewed: return "Items you've reviewed will appear here"
        case .all: return "Import calendar events to get started"
        }
    }

    // MARK: - Loading State

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading evidence...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Error State

    private func errorView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Error", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") {
                Task {
                    await loadItems()
                }
            }
        }
    }

    // MARK: - Import Status Badge

    @ViewBuilder
    private var importStatusBadge: some View {
        if importCoordinator.importStatus == .importing {
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Importing...")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        } else if let lastImport = importCoordinator.lastImportedAt {
            Text("\(importCoordinator.lastImportCount) events \(lastImport, style: .relative) ago")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let error = importCoordinator.lastError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }

    // MARK: - Data Operations

    private func loadItems() async {
        isLoading = true
        errorMessage = nil

        do {
            let allItems: [SamEvidenceItem]
            switch filter {
            case .needsReview:
                allItems = try repository.fetchNeedsReview()
            case .reviewed:
                allItems = try repository.fetchDone()
            case .all:
                allItems = try repository.fetchAll()
            }

            // Client-side search filter
            if searchText.isEmpty {
                items = allItems
            } else {
                let query = searchText.lowercased()
                items = allItems.filter { item in
                    item.title.lowercased().contains(query) ||
                    item.snippet.lowercased().contains(query)
                }
            }

        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

// MARK: - Evidence Filter

private enum EvidenceFilter: String, CaseIterable {
    case needsReview
    case reviewed
    case all

    var label: String {
        switch self {
        case .needsReview: return "Needs Review"
        case .reviewed: return "Reviewed"
        case .all: return "All"
        }
    }
}

// MARK: - Evidence Row View

private struct EvidenceRowView: View {
    let item: SamEvidenceItem

    var body: some View {
        HStack(spacing: 12) {
            // Source icon
            Image(systemName: sourceIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)
                .foregroundStyle(sourceColor)
                .frame(width: 32, height: 32)

            // Title and snippet
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body)
                    .lineLimit(1)

                Text(item.snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            // Date and state badge
            VStack(alignment: .trailing, spacing: 4) {
                Text(item.occurredAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                stateBadge
            }
        }
        .padding(.vertical, 4)
    }

    private var sourceIcon: String {
        switch item.source {
        case .calendar: return "calendar"
        case .mail: return "envelope"
        case .contacts: return "person.crop.circle"
        case .note: return "note.text"
        case .manual: return "square.and.pencil"
        }
    }

    private var sourceColor: Color {
        switch item.source {
        case .calendar: return .red
        case .mail: return .blue
        case .contacts: return .green
        case .note: return .orange
        case .manual: return .purple
        }
    }

    private var stateBadge: some View {
        Text(item.state == .needsReview ? "Review" : "Done")
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(item.state == .needsReview ? Color.orange.opacity(0.2) : Color.green.opacity(0.2))
            .foregroundStyle(item.state == .needsReview ? .orange : .green)
            .clipShape(Capsule())
    }
}

// MARK: - Preview

#Preview("With Items") {
    let container = SAMModelContainer.shared
    EvidenceRepository.shared.configure(container: container)

    let context = ModelContext(container)

    let item1 = SamEvidenceItem(
        id: UUID(),
        state: .needsReview,
        source: .calendar,
        occurredAt: Date(),
        title: "Meeting with John Doe",
        snippet: "Quarterly portfolio review at downtown office"
    )

    let item2 = SamEvidenceItem(
        id: UUID(),
        state: .done,
        source: .calendar,
        occurredAt: Date().addingTimeInterval(-86400),
        title: "Smith Family Check-in",
        snippet: "Annual insurance review and beneficiary updates"
    )

    context.insert(item1)
    context.insert(item2)
    try? context.save()

    return NavigationStack {
        InboxListView(selectedEvidenceID: .constant(nil))
            .modelContainer(container)
    }
    .frame(width: 400, height: 600)
}

#Preview("Empty") {
    let container = SAMModelContainer.shared
    EvidenceRepository.shared.configure(container: container)

    return NavigationStack {
        InboxListView(selectedEvidenceID: .constant(nil))
            .modelContainer(container)
    }
    .frame(width: 400, height: 600)
}
