//
//  MockContextRuntimeStore.swift
//  SAM_crm
//
//  Created by David Snyder on 2/1/26.
//

import SwiftUI
import Observation

@MainActor
@Observable
final class MockContextRuntimeStore {
    static let shared = MockContextRuntimeStore()

    private(set) var all: [ContextDetailModel] = MockContextStore.all

    var byID: [UUID: ContextDetailModel] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    }

    var listItems: [ContextListItemModel] {
        all.map { ctx in
            ContextListItemModel(
                id: ctx.id,
                name: ctx.name,
                subtitle: ctx.listSubtitle,
                kind: ctx.kind,
                consentCount: ctx.alerts.consentCount,
                reviewCount: ctx.alerts.reviewCount,
                followUpCount: ctx.alerts.followUpCount
            )
        }
    }

    func add(_ draft: NewContextDraft) -> UUID {
        let newID = UUID()

        // Minimal “starter” participant so detail doesn’t look empty
        let starterParticipants: [ContextParticipantModel] = draft.includeDefaultParticipants
        ? [
            ContextParticipantModel(
                id: UUID(),
                displayName: "Primary Person",
                roleBadges: ["Client"],
                icon: "person.crop.circle",
                isPrimary: true,
                note: nil
            )
          ]
        : []

        let created = ContextDetailModel(
            id: newID,
            name: draft.name,
            kind: draft.kind,
            alerts: ContextAlerts(consentCount: 0, reviewCount: 0, followUpCount: 0),
            participants: starterParticipants,
            products: [],
            consentRequirements: [],
            recentInteractions: [],
            insights: []
        )

        all.insert(created, at: 0)
        return newID
    }
    
    func addParticipant(contextID: UUID, personID: UUID, displayName: String, role: RelationshipRole) {
        guard let idx = all.firstIndex(where: { $0.id == contextID }) else { return }

        // Prevent duplicates (same person already in context)
        if all[idx].participants.contains(where: { $0.id == personID }) {
            return
        }

        let participant = ContextParticipantModel(
            id: personID,                         // stable: same as person
            displayName: displayName,
            roleBadges: role.roleBadges,
            icon: role.icon,
            isPrimary: role.makesPrimary,
            note: nil
        )

        var ctx = all[idx]
        ctx = ContextDetailModel(
            id: ctx.id,
            name: ctx.name,
            kind: ctx.kind,
            alerts: ctx.alerts,
            participants: ctx.participants + [participant],
            products: ctx.products,
            consentRequirements: ctx.consentRequirements,
            recentInteractions: ctx.recentInteractions,
            insights: ctx.insights
        )

        all[idx] = ctx
    }
}
