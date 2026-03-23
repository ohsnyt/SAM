//
//  AddParticipantsSheet.swift
//  SAM
//
//  Created on March 11, 2026.
//  Search and add contacts to an event, with AI-powered suggestions.
//

import SwiftUI

struct AddParticipantsSheet: View {

    let event: SamEvent
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var searchResults: [SamPerson] = []
    @State private var suggestions: [(person: SamPerson, reason: String)] = []
    @State private var isLoadingSuggestions = true
    @State private var selectedPeople: Set<UUID> = []
    @State private var priorityOverrides: [UUID: ParticipantPriority] = [:]
    @State private var roleOverrides: [UUID: String] = [:]
    @State private var addedCount = 0

    private var existingPersonIDs: Set<UUID> {
        Set(EventRepository.shared.fetchParticipations(for: event).compactMap { $0.person?.id })
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Add Participants")
                    .samFont(.title2, weight: .bold)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(addedCount > 0 ? .accentColor : .gray)
                    .keyboardShortcut(.escape)
            }
            .padding()

            Divider()

            HSplitView {
                // Left: search + suggestions
                VStack(spacing: 0) {
                    // Search bar
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search contacts…", text: $searchText)
                            .textFieldStyle(.plain)
                    }
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    Divider()

                    if searchText.isEmpty {
                        // Show AI suggestions
                        suggestionsSection
                    } else {
                        // Show search results
                        searchResultsList
                    }
                }
                .frame(minWidth: 300, idealWidth: 380)

                // Right: selected people summary
                selectedSummary
                    .frame(minWidth: 250, idealWidth: 300)
            }

            Divider()

            // Footer
            HStack {
                if addedCount > 0 {
                    Text("\(addedCount) added")
                        .samFont(.caption)
                        .foregroundStyle(.green)
                }
                Spacer()
                Button("Add Selected (\(selectedPeople.count))") {
                    addSelectedPeople()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedPeople.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
        .frame(width: 700, height: 550)
        .onChange(of: searchText) { _, newValue in
            performSearch(query: newValue)
        }
        .task {
            await loadSuggestions()
        }
    }

    // MARK: - Suggestions Section

    private var suggestionsSection: some View {
        Group {
            if isLoadingSuggestions {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("SAM is analyzing your contacts…")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if suggestions.isEmpty {
                ContentUnavailableView(
                    "No Suggestions",
                    systemImage: "person.2",
                    description: Text("Search for contacts to add")
                )
            } else {
                List {
                    Section("SAM's Suggestions") {
                        ForEach(suggestions, id: \.person.id) { suggestion in
                            personRow(suggestion.person, reason: suggestion.reason)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    // MARK: - Search Results

    private var searchResultsList: some View {
        List {
            if searchResults.isEmpty {
                ContentUnavailableView(
                    "No Matches",
                    systemImage: "magnifyingglass",
                    description: Text("No contacts match \"\(searchText)\"")
                )
            } else {
                ForEach(searchResults, id: \.id) { person in
                    personRow(person, reason: nil)
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Person Row

    private func personRow(_ person: SamPerson, reason: String?) -> some View {
        let isAlreadyAdded = existingPersonIDs.contains(person.id)
        let isSelected = selectedPeople.contains(person.id)

        return HStack(spacing: 8) {
            // Selection checkbox
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? .blue : .secondary)
                .samFont(.body)

            VStack(alignment: .leading, spacing: 2) {
                Text(person.displayNameCache ?? "Unknown")
                    .samFont(.body)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if !person.roleBadges.isEmpty {
                        ForEach(person.roleBadges.prefix(3), id: \.self) { badge in
                            Text(badge)
                                .samFont(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }

                    if let reason {
                        Text(reason)
                            .samFont(.caption2)
                            .foregroundStyle(.blue)
                            .italic()
                    }
                }
            }

            Spacer()

            if isAlreadyAdded {
                Text("Already added")
                    .samFont(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isAlreadyAdded else { return }
            if isSelected {
                selectedPeople.remove(person.id)
            } else {
                selectedPeople.insert(person.id)
            }
        }
        .opacity(isAlreadyAdded ? 0.5 : 1.0)
    }

    // MARK: - Selected Summary

    private var selectedSummary: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Selected (\(selectedPeople.count))")
                .samFont(.headline)
                .padding(12)

            Divider()

            if selectedPeople.isEmpty {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "person.badge.plus",
                    description: Text("Tap contacts on the left to select them")
                )
            } else {
                List {
                    ForEach(selectedPersonObjects, id: \.id) { person in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(person.displayNameCache ?? "Unknown")
                                    .samFont(.body)
                                Spacer()
                                Button {
                                    selectedPeople.remove(person.id)
                                } label: {
                                    Image(systemName: "xmark.circle")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }

                            HStack(spacing: 8) {
                                Picker("Priority", selection: priorityBinding(for: person.id)) {
                                    ForEach(ParticipantPriority.allCases, id: \.self) { p in
                                        Text(p.displayName).tag(p)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .frame(maxWidth: 200)

                                TextField("Role", text: roleBinding(for: person.id))
                                    .textFieldStyle(.roundedBorder)
                                    .samFont(.caption)
                                    .frame(maxWidth: 100)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    // MARK: - Helpers

    private var selectedPersonObjects: [SamPerson] {
        let allPeople = (try? PeopleRepository.shared.fetchAll()) ?? []
        return allPeople.filter { selectedPeople.contains($0.id) }
    }

    private func priorityBinding(for personID: UUID) -> Binding<ParticipantPriority> {
        Binding(
            get: { priorityOverrides[personID] ?? .standard },
            set: { priorityOverrides[personID] = $0 }
        )
    }

    private func roleBinding(for personID: UUID) -> Binding<String> {
        Binding(
            get: { roleOverrides[personID] ?? "Attendee" },
            set: { roleOverrides[personID] = $0 }
        )
    }

    private func performSearch(query: String) {
        guard !query.isEmpty else {
            searchResults = []
            return
        }
        searchResults = ((try? PeopleRepository.shared.search(query: query)) ?? [])
            .filter { $0.lifecycleStatus == .active && !$0.isMe }
    }

    private func loadSuggestions() async {
        isLoadingSuggestions = true
        do {
            let suggestLimit = max(30, event.targetParticipantCount * 2)
            suggestions = try await EventCoordinator.shared.suggestInvitationList(for: event, limit: suggestLimit)
        } catch {
            suggestions = []
        }
        isLoadingSuggestions = false
    }

    private func addSelectedPeople() {
        let allPeople = (try? PeopleRepository.shared.fetchAll()) ?? []
        let people = allPeople.filter { selectedPeople.contains($0.id) }

        let entries: [(person: SamPerson, priority: ParticipantPriority, role: String)] = people.map { person in
            (
                person: person,
                priority: priorityOverrides[person.id] ?? .standard,
                role: roleOverrides[person.id] ?? "Attendee"
            )
        }

        do {
            let added = try EventCoordinator.shared.addParticipants(to: event, people: entries)
            addedCount += added.count
            selectedPeople.removeAll()
            priorityOverrides.removeAll()
            roleOverrides.removeAll()
        } catch {
            // Error adding participants
        }
    }
}
