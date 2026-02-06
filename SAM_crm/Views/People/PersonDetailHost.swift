//
//  PersonDetailHost.swift
//  SAM_crm
//
//  Created by David Snyder on 1/31/26.
//

import SwiftUI
import SwiftData

struct PersonDetailHost: View {
    let selectedPersonID: UUID?
    
    @Query private var people: [SamPerson]
    @Query(sort: [SortDescriptor(\SamContext.name, comparator: .localizedStandard)]) private var allContexts: [SamContext]
    @Environment(\.modelContext) private var modelContext

    init(selectedPersonID: UUID?) {
        self.selectedPersonID = selectedPersonID
        if let id = selectedPersonID {
            _people = Query(filter: #Predicate<SamPerson> { $0.id == id })
        } else {
            _people = Query()
        }
    }

    @State private var showingAddToContextSheet: Bool = false

    var body: some View {
        if let personModel = people.first.map(mapToDetailModel(_:)) {
            PersonDetailView(person: personModel)
                .toolbar {
                    ToolbarItemGroup {
                        Button {
                            showingAddToContextSheet = true
                        } label: {
                            Label("Add to Context", systemImage: "person.badge.plus")
                        }
                        .buttonStyle(.glass)
                        .help("Add this person to a context")
                        .keyboardShortcut("k", modifiers: [.command])
                    }
                }
                .sheet(isPresented: $showingAddToContextSheet) {
                    let contextItems: [ContextListItemModel] = allContexts.map { ctx in
                        ContextListItemModel(
                            id: ctx.id,
                            name: ctx.name,
                            subtitle: ctx.kind.displayName,
                            kind: ctx.kind,
                            consentCount: ctx.consentAlertCount,
                            reviewCount: ctx.reviewAlertCount,
                            followUpCount: ctx.followUpAlertCount
                        )
                    }
                    AddPersonToContextSheet(
                        personID: personModel.id,
                        personName: personModel.displayName,
                        contexts: contextItems
                    ) { contextID, role in
                        // Resolve live SamPerson from SwiftData
                        guard let person = people.first(where: { $0.id == personModel.id }) else { return }

                        do {
                            // Fetch SamContext by ID
                            let ctxFetch = FetchDescriptor<SamContext>(
                                predicate: #Predicate { $0.id == contextID }
                            )
                            let contexts = try modelContext.fetch(ctxFetch)
                            guard let samContext = contexts.first else { return }

                            // 1) Create participation link
                            let participation = ContextParticipation(
                                id: UUID(),
                                person: person,
                                context: samContext,
                                roleBadges: [role.rawValue],
                                isPrimary: false,
                                note: nil,
                                startDate: .now
                            )
                            modelContext.insert(participation)
                            person.participations.append(participation)
                            samContext.participations.append(participation)

                            // 2) Update denormalized contextChips for immediate UI
                            let chip = ContextChip(
                                id: samContext.id,
                                name: samContext.name,
                                kindDisplay: samContext.kind.displayName,
                                icon: samContext.kind.icon
                            )
                            if !person.contextChips.contains(where: { $0.id == chip.id }) {
                                person.contextChips.append(chip)
                            }

                            // 3) Persist changes
                            try modelContext.save()
                        } catch {
                            // TODO: handle error (optional UI alert)
                        }
                    }
                }
        } else {
            ContentUnavailableView(
                "Select a person",
                systemImage: "person.crop.circle",
                description: Text("Choose someone from the People list.")
            )
            .padding()
        }
    }

    private func mapToDetailModel(_ p: SamPerson) -> PersonDetailModel {
        // Derive context chips from either relationship or denormalized chips
        let chips: [ContextChip]
        if !p.contextChips.isEmpty {
            chips = p.contextChips
        } else {
            // Fallback: derive from participations if available
            chips = p.participations.compactMap { part -> ContextChip? in
                guard let ctx = part.context else { return nil }
                return ContextChip(
                    id: ctx.id,
                    name: ctx.name,
                    kindDisplay: ctx.kind.displayName,
                    icon: ctx.kind.icon
                )
            }
        }
        
        // Convert domain insights to view-model insights
        let insights: [SamInsight] = p.insights

        return PersonDetailModel(
            id: p.id,
            displayName: p.displayName,
            roleBadges: p.roleBadges,
            contactIdentifier: p.contactIdentifier,
            email: p.email,
            consentAlertsCount: p.consentAlertsCount,
            reviewAlertsCount: p.reviewAlertsCount,
            contexts: chips,
            responsibilityNotes: p.responsibilityNotes,
            recentInteractions: p.recentInteractions,
            insights: insights
        )
    }
}

