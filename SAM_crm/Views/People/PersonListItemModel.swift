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
}
