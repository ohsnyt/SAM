//
//  SearchCoordinator.swift
//  SAM
//
//  Created by Assistant on 2/26/26.
//  Advanced Search — cross-type full-text search coordinator.
//
//  NOT a singleton — instantiated per SearchView.
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "SearchCoordinator")

// MARK: - Search Types

enum SearchScope: String, CaseIterable {
    case all = "All"
    case people = "People"
    case contexts = "Contexts"
    case notes = "Notes"
    case evidence = "Evidence"
    case insights = "Insights"
    case outcomes = "Outcomes"
}

enum SearchResultSelection: Hashable {
    case person(UUID)
    case context(UUID)
    case note(UUID)
    case evidence(UUID)
    case insight(UUID)
    case outcome(UUID)
}

// MARK: - SearchCoordinator

@MainActor
@Observable
final class SearchCoordinator {

    // MARK: - State

    var searchText: String = ""
    var scope: SearchScope = .all
    var isSearching: Bool = false

    var peopleResults: [SamPerson] = []
    var contextResults: [SamContext] = []
    var noteResults: [SamNote] = []
    var evidenceResults: [SamEvidenceItem] = []
    var insightResults: [SamInsight] = []
    var outcomeResults: [SamOutcome] = []

    var totalCount: Int {
        peopleResults.count + contextResults.count + noteResults.count +
        evidenceResults.count + insightResults.count + outcomeResults.count
    }

    // MARK: - Dependencies

    private let peopleRepository = PeopleRepository.shared
    private let contextsRepository = ContextsRepository.shared
    private let notesRepository = NotesRepository.shared
    private let evidenceRepository = EvidenceRepository.shared
    private let outcomeRepository = OutcomeRepository.shared
    private var insightContext: ModelContext?

    // MARK: - Configuration

    func configure(container: ModelContainer) {
        self.insightContext = ModelContext(container)
    }

    // MARK: - Search

    func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            clearResults()
            return
        }

        isSearching = true
        defer { isSearching = false }

        let lowercaseQuery = query.lowercased()

        do {
            // People
            if scope == .all || scope == .people {
                let allPeople = try peopleRepository.search(query: query)
                peopleResults = allPeople.filter { person in
                    let name = (person.displayNameCache ?? person.displayName).lowercased()
                    let email = person.emailCache?.lowercased() ?? ""
                    let badges = person.roleBadges.joined(separator: " ").lowercased()
                    return name.contains(lowercaseQuery) ||
                           email.contains(lowercaseQuery) ||
                           badges.contains(lowercaseQuery)
                }
            } else {
                peopleResults = []
            }

            // Contexts
            if scope == .all || scope == .contexts {
                contextResults = try contextsRepository.search(query: query)
            } else {
                contextResults = []
            }

            // Notes
            if scope == .all || scope == .notes {
                noteResults = try notesRepository.search(query: query)
            } else {
                noteResults = []
            }

            // Evidence
            if scope == .all || scope == .evidence {
                evidenceResults = try evidenceRepository.search(query: query)
            } else {
                evidenceResults = []
            }

            // Insights
            if scope == .all || scope == .insights {
                insightResults = searchInsights(query: lowercaseQuery)
            } else {
                insightResults = []
            }

            // Outcomes
            if scope == .all || scope == .outcomes {
                outcomeResults = try outcomeRepository.search(query: query)
            } else {
                outcomeResults = []
            }
        } catch {
            logger.error("Search failed: \(error)")
        }
    }

    func clearResults() {
        peopleResults = []
        contextResults = []
        noteResults = []
        evidenceResults = []
        insightResults = []
        outcomeResults = []
    }

    // MARK: - Insight Search (via own ModelContext)

    private func searchInsights(query: String) -> [SamInsight] {
        guard let context = insightContext else { return [] }

        do {
            let descriptor = FetchDescriptor<SamInsight>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            let all = try context.fetch(descriptor)
            return all.filter { insight in
                insight.dismissedAt == nil && (
                    insight.title.lowercased().contains(query) ||
                    insight.message.lowercased().contains(query)
                )
            }
        } catch {
            logger.error("Insight search failed: \(error)")
            return []
        }
    }
}
