//
//  SearchView.swift
//  SAM
//
//  Created by Assistant on 2/26/26.
//  Advanced Search — full-text search across all data types.
//

import SwiftUI
import SwiftData
import TipKit

struct SearchView: View {

    @State private var coordinator = SearchCoordinator()
    @State private var selectedResult: SearchResultSelection?
    @State private var searchTask: Task<Void, Never>?
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        HSplitView {
            resultsList
                .frame(minWidth: 250, idealWidth: 350)

            detailPane
                .frame(minWidth: 300)
        }
        .onAppear {
            if let container = modelContext.container as ModelContainer? {
                coordinator.configure(container: container)
            }
        }
    }

    // MARK: - Results List

    @ViewBuilder
    private var resultsList: some View {
        List(selection: $selectedResult) {
            if coordinator.searchText.isEmpty {
                // Empty state — no search yet
            } else if coordinator.totalCount == 0 && !coordinator.isSearching {
                // No results
            } else {
                if !coordinator.peopleResults.isEmpty {
                    Section("People (\(coordinator.peopleResults.count))") {
                        ForEach(coordinator.peopleResults, id: \.id) { person in
                            SearchPersonRow(person: person)
                                .tag(SearchResultSelection.person(person.id))
                        }
                    }
                }

                if !coordinator.contextResults.isEmpty {
                    Section("Contexts (\(coordinator.contextResults.count))") {
                        ForEach(coordinator.contextResults, id: \.id) { context in
                            SearchContextRow(context: context)
                                .tag(SearchResultSelection.context(context.id))
                        }
                    }
                }

                if !coordinator.noteResults.isEmpty {
                    Section("Notes (\(coordinator.noteResults.count))") {
                        ForEach(coordinator.noteResults, id: \.id) { note in
                            SearchNoteRow(note: note)
                                .tag(SearchResultSelection.note(note.id))
                        }
                    }
                }

                if !coordinator.evidenceResults.isEmpty {
                    Section("Evidence (\(coordinator.evidenceResults.count))") {
                        ForEach(coordinator.evidenceResults, id: \.id) { item in
                            SearchEvidenceRow(item: item)
                                .tag(SearchResultSelection.evidence(item.id))
                        }
                    }
                }

                if !coordinator.insightResults.isEmpty {
                    Section("Insights (\(coordinator.insightResults.count))") {
                        ForEach(coordinator.insightResults, id: \.id) { insight in
                            SearchInsightRow(insight: insight)
                                .tag(SearchResultSelection.insight(insight.id))
                        }
                    }
                }

                if !coordinator.outcomeResults.isEmpty {
                    Section("Outcomes (\(coordinator.outcomeResults.count))") {
                        ForEach(coordinator.outcomeResults, id: \.id) { outcome in
                            SearchOutcomeRow(outcome: outcome)
                                .tag(SearchResultSelection.outcome(outcome.id))
                        }
                    }
                }
            }
        }
        .searchable(text: $coordinator.searchText, prompt: "Search everything")
        .popoverTip(SearchTip(), arrowEdge: .top)
        .searchScopes($coordinator.scope) {
            ForEach(SearchScope.allCases, id: \.self) { scope in
                Text(scope.rawValue).tag(scope)
            }
        }
        .overlay {
            if coordinator.searchText.isEmpty {
                ContentUnavailableView(
                    "Search SAM",
                    systemImage: "magnifyingglass",
                    description: Text("Find people, notes, evidence, and more")
                )
            } else if coordinator.totalCount == 0 && !coordinator.isSearching {
                ContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text("No matches for \"\(coordinator.searchText)\"")
                )
            }
        }
        .onChange(of: coordinator.searchText) { _, newValue in
            searchTask?.cancel()
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                coordinator.clearResults()
                selectedResult = nil
            } else {
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    coordinator.performSearch()
                }
            }
        }
        .onChange(of: coordinator.scope) { _, _ in
            guard !coordinator.searchText.isEmpty else { return }
            coordinator.performSearch()
        }
    }

    // MARK: - Detail Pane

    @ViewBuilder
    private var detailPane: some View {
        switch selectedResult {
        case .person(let id):
            SearchPersonDetailContainer(personID: id)
                .id(id)
        case .context(let id):
            SearchContextDetailContainer(contextID: id)
                .id(id)
        case .evidence(let id):
            SearchEvidenceDetailContainer(evidenceID: id)
                .id(id)
        case .note(let id):
            SearchNoteDetailContainer(noteID: id)
                .id(id)
        case .insight(let id):
            SearchInsightDetailContainer(insightID: id)
                .id(id)
        case .outcome(let id):
            SearchOutcomeDetailContainer(outcomeID: id)
                .id(id)
        case nil:
            ContentUnavailableView(
                "Select a Result",
                systemImage: "text.magnifyingglass",
                description: Text("Choose a search result to view its details")
            )
        }
    }
}

// MARK: - Detail Containers

private struct SearchPersonDetailContainer: View {
    let personID: UUID
    @Query private var allPeople: [SamPerson]

    var body: some View {
        if let person = allPeople.first(where: { $0.id == personID }) {
            PersonDetailView(person: person)
                .id(personID)
        } else {
            ContentUnavailableView("Person Not Found", systemImage: "person.crop.circle.badge.questionmark")
        }
    }
}

private struct SearchContextDetailContainer: View {
    let contextID: UUID
    @Query private var allContexts: [SamContext]

    var body: some View {
        if let context = allContexts.first(where: { $0.id == contextID }) {
            ContextDetailView(context: context)
                .id(contextID)
        } else {
            ContentUnavailableView("Context Not Found", systemImage: "building.2.crop.circle.badge.questionmark")
        }
    }
}

private struct SearchEvidenceDetailContainer: View {
    let evidenceID: UUID
    @Query private var allItems: [SamEvidenceItem]

    var body: some View {
        if let item = allItems.first(where: { $0.id == evidenceID }) {
            InboxDetailView(item: item)
                .id(evidenceID)
        } else {
            ContentUnavailableView("Evidence Not Found", systemImage: "tray.slash")
        }
    }
}

private struct SearchNoteDetailContainer: View {
    let noteID: UUID
    @Query private var allNotes: [SamNote]

    var body: some View {
        if let note = allNotes.first(where: { $0.id == noteID }) {
            NoteDetailReadOnlyView(note: note)
                .id(noteID)
        } else {
            ContentUnavailableView("Note Not Found", systemImage: "note.text")
        }
    }
}

private struct SearchInsightDetailContainer: View {
    let insightID: UUID
    @Query private var allInsights: [SamInsight]

    var body: some View {
        if let insight = allInsights.first(where: { $0.id == insightID }) {
            InsightDetailReadOnlyView(insight: insight)
                .id(insightID)
        } else {
            ContentUnavailableView("Insight Not Found", systemImage: "lightbulb")
        }
    }
}

private struct SearchOutcomeDetailContainer: View {
    let outcomeID: UUID
    @Query private var allOutcomes: [SamOutcome]

    var body: some View {
        if let outcome = allOutcomes.first(where: { $0.id == outcomeID }) {
            OutcomeDetailReadOnlyView(outcome: outcome)
                .id(outcomeID)
        } else {
            ContentUnavailableView("Outcome Not Found", systemImage: "target")
        }
    }
}

// MARK: - Read-Only Detail Views

private struct NoteDetailReadOnlyView: View {
    let note: SamNote

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    Image(systemName: "note.text")
                        .foregroundStyle(.orange)
                    Text("Note")
                        .font(.headline)
                    Spacer()
                    Text(note.updatedAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                // Summary
                if let summary = note.summary, !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Summary")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Text(summary)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }

                // Content
                VStack(alignment: .leading, spacing: 4) {
                    Text("Content")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(note.content)
                        .font(.body)
                        .textSelection(.enabled)
                }

                // Linked People
                if !note.linkedPeople.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Linked People")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        ForEach(note.linkedPeople, id: \.id) { person in
                            HStack(spacing: 6) {
                                Image(systemName: "person.circle.fill")
                                    .foregroundStyle(.secondary)
                                Text(person.displayNameCache ?? person.displayName)
                            }
                            .font(.body)
                        }
                    }
                }

                // Action Items
                if !note.extractedActionItems.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Action Items")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        ForEach(note.extractedActionItems, id: \.description) { item in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "checkmark.circle")
                                    .foregroundStyle(.blue)
                                Text(item.description)
                            }
                            .font(.body)
                        }
                    }
                }
            }
            .padding()
        }
    }
}

private struct InsightDetailReadOnlyView: View {
    let insight: SamInsight

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(.yellow)
                    Text(insight.title)
                        .font(.headline)
                    Spacer()
                    Text(insight.urgency.displayText)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(urgencyColor)
                        .clipShape(Capsule())
                }

                Divider()

                // Message
                Text(insight.message)
                    .font(.body)
                    .textSelection(.enabled)

                // Linked Person
                if let person = insight.samPerson {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Related Person")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        HStack(spacing: 6) {
                            Image(systemName: "person.circle.fill")
                                .foregroundStyle(.secondary)
                            Text(person.displayNameCache ?? person.displayName)
                        }
                        .font(.body)
                    }
                }

                // Metadata
                HStack(spacing: 16) {
                    Text(insight.createdAt, format: .dateTime.month().day().year())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
    }

    private var urgencyColor: Color {
        switch insight.urgency {
        case .low: return .gray
        case .medium: return .orange
        case .high: return .red
        }
    }
}

private struct OutcomeDetailReadOnlyView: View {
    let outcome: SamOutcome

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    Circle()
                        .fill(outcome.outcomeKind.themeColor)
                        .frame(width: 12, height: 12)
                    Text(outcome.title)
                        .font(.headline)
                    Spacer()
                    Text(outcome.outcomeKind.displayName)
                        .font(.caption)
                        .foregroundStyle(outcome.outcomeKind.themeColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(outcome.outcomeKind.themeColor.opacity(0.12))
                        .clipShape(Capsule())
                }

                Divider()

                // Rationale
                VStack(alignment: .leading, spacing: 4) {
                    Text("Why")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(outcome.rationale)
                        .font(.body)
                        .textSelection(.enabled)
                }

                // Next Step
                if let nextStep = outcome.suggestedNextStep, !nextStep.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Next Step")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Text(nextStep)
                            .font(.body)
                    }
                }

                // Deadline
                if let deadline = outcome.deadlineDate {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar.badge.clock")
                            .foregroundStyle(.red)
                        Text("Due: \(deadline, format: .dateTime.month().day().year())")
                            .font(.body)
                    }
                }

                // Linked Person
                if let person = outcome.linkedPerson {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Related Person")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        HStack(spacing: 6) {
                            Image(systemName: "person.circle.fill")
                                .foregroundStyle(.secondary)
                            Text(person.displayNameCache ?? person.displayName)
                        }
                        .font(.body)
                    }
                }

                // Status
                HStack(spacing: 6) {
                    Text("Status:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(outcome.status.rawValue.capitalized)
                        .font(.caption)
                        .fontWeight(.medium)
                }
            }
            .padding()
        }
    }
}
