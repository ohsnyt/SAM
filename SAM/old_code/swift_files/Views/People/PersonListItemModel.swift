//
//  PersonListItemModel.swift
//  SAM_crm
//
//  Created by David Snyder on 2/1/26.
//

import SwiftUI

struct PersonListItemModel: Identifiable {
    let id: UUID
    let displayName: String
    let roleBadges: [String]
    let consentAlertsCount: Int
    let reviewAlertsCount: Int
    let contactIdentifier: String?
    
    /// Returns true if this person is the me card
    var isMeCard: Bool {
        guard let contactIdentifier = contactIdentifier,
              let meCardIdentifier = MainActor.assumeIsolated({ MeCardManager.shared.meCardIdentifier }) else {
            return false
        }
        return contactIdentifier == meCardIdentifier
    }
}

