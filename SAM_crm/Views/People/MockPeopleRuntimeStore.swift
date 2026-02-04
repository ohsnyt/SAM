//
//  MockPeopleRuntimeStore.swift
//  SAM_crm
//
//  Created by David Snyder on 2/1/26.
//

import SwiftUI
import Observation
#if canImport(Contacts)
import Contacts
#endif

@MainActor
@Observable
final class MockPeopleRuntimeStore {
    static let shared = MockPeopleRuntimeStore()
    
    private(set) var all: [PersonDetailModel] = MockPeopleStore.all

    /// Wholesale replace — used by backup restore.
    func replaceAll(with newPeople: [PersonDetailModel]) {
        all = newPeople
    }
    
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
            contactIdentifier: draft.contactIdentifier,
            email: draft.email,
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

    /// A single long-lived CNContactStore shared across all resolution
    /// calls.  CNContactStore registers an internal change-history anchor
    /// on init; creating one per call races that registration and produces
    /// "CNAccountCollectionUpdateWatcher … store registration failed" noise.
    #if canImport(Contacts)
    private static let contactStore = CNContactStore()
    #endif

    /// Looks up a person by email and, if found in CNContactStore, patches
    /// their `contactIdentifier` so future photo lookups use the fast
    /// identifier path.  Safe to call repeatedly — it's a no-op if the
    /// person already has an identifier or if Contacts access is denied.
    func resolveContactIdentifier(personID: UUID) {
        guard let idx = all.firstIndex(where: { $0.id == personID }) else { return }
        guard all[idx].contactIdentifier == nil else { return }   // already resolved
        guard let email = all[idx].email else { return }          // nothing to look up

        #if canImport(Contacts)
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return }

        let predicate = CNContact.predicateForContacts(matchingEmailAddress: email)
        guard let contact = try? Self.contactStore.unifiedContacts(
            matching: predicate,
            keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor]
        ).first else { return }

        all[idx].contactIdentifier = contact.identifier
        #endif
    }

    /// Directly sets the `contactIdentifier` on an existing person.
    /// Use this when the caller already has the identifier in hand (e.g. from
    /// a CNContact that was just resolved for another purpose) to avoid a
    /// redundant second query.
    func patchContactIdentifier(personID: UUID, identifier: String) {
        guard let idx = all.firstIndex(where: { $0.id == personID }) else { return }
        all[idx].contactIdentifier = identifier
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
