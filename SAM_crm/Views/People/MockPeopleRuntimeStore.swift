//
//  MockPeopleRuntimeStore.swift
//  SAM_crm
//
//  Created by David Snyder on 2/1/26.
//

import SwiftUI
import Observation

@MainActor
@Observable
final class MockPeopleRuntimeStore {
    static let shared = MockPeopleRuntimeStore()
    
    private(set) var all: [PersonDetailModel] = MockPeopleStore.all
    
    var byID: [UUID: PersonDetailModel] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    }
    
    var listItems: [PersonListItemModel] {
        all.map { p in
            PersonListItemModel(
                id: p.id,
                displayName: p.displayName,
                roleBadges: p.roleBadges,
                consentAlertsCount: p.consentAlertsCount,
                reviewAlertsCount: p.reviewAlertsCount
            )
        }
    }
    
    func add(_ draft: NewPersonDraft) -> UUID {
        let id = UUID()
        let created = PersonDetailModel(
            id: id,
            displayName: draft.fullName,
            roleBadges: draft.rolePreset.roleBadges,
            consentAlertsCount: 0,
            reviewAlertsCount: 0,
            contexts: [],
            responsibilityNotes: [],
            recentInteractions: [],
            insights: []
        )
        all.insert(created, at: 0)
        return id
    }
    
    func addContext(personID: UUID, context: ContextListItemModel) {
        guard let idx = all.firstIndex(where: { $0.id == personID }) else { return }
        
        // Prevent duplicates
        if all[idx].contexts.contains(where: { $0.name == context.name && $0.kindDisplay == context.kind.displayName }) {
            return
        }
        
        let chip = ContextChip(
            name: context.name,
            kindDisplay: context.kind.displayName,
            icon: context.kind.icon
        )
        
        var p = all[idx]
        p = PersonDetailModel(
            id: p.id,
            displayName: p.displayName,
            roleBadges: p.roleBadges,
            consentAlertsCount: p.consentAlertsCount,
            reviewAlertsCount: p.reviewAlertsCount,
            contexts: p.contexts + [chip],
            responsibilityNotes: p.responsibilityNotes,
            recentInteractions: p.recentInteractions,
            insights: p.insights
        )
        
        all[idx] = p
    }
}
