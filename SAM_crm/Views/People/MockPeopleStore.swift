//
//  MockPeopleStore.swift
//  SAM_crm
//
//  Created by David Snyder on 2/1/26.
//

import SwiftUI

enum MockPeopleStore {
    static let all: [PersonDetailModel] = [
        PersonDetailModel(
            id: UUID(),
            displayName: "Mary Smith",
            roleBadges: ["Client", "Household", "Joint Signer"],
            consentAlertsCount: 2,
            reviewAlertsCount: 1,
            contexts: [
                ContextChip(name: "John & Mary Smith", kindDisplay: "Household", icon: "house"),
                ContextChip(name: "ABC Manufacturing", kindDisplay: "Business", icon: "building.2")
            ],
            responsibilityNotes: [
                "Guardian/responsible person for Emma Smith (minor)."
            ],
            recentInteractions: [
                InteractionChip(title: "Zoom call", subtitle: "Policy review follow-up", whenText: "2d", icon: "video"),
                InteractionChip(title: "Message", subtitle: "Asked about schedule", whenText: "5d", icon: "message")
            ],
            insights: [
                PersonMockInsight(kind: .relationshipAtRisk,
                                  message: "Possible household structure change detected for John and Mary Smith.",
                                  confidence: 0.72,
                                  interactionsCount: 3,
                                  consentsCount: 0),
                PersonMockInsight(kind: .consentMissing,
                                  message: "Spousal consent is no longer valid for an active household policy.",
                                  confidence: 0.95,
                                  interactionsCount: 1,
                                  consentsCount: 2)
            ]
        ),
        PersonDetailModel(
            id: UUID(),
            displayName: "Evan Patel",
            roleBadges: ["Referral Partner", "Estate Planning Attorney"],
            consentAlertsCount: 0,
            reviewAlertsCount: 0,
            contexts: [
                ContextChip(name: "Referral Network", kindDisplay: "Partner", icon: "person.3")
            ],
            responsibilityNotes: [],
            recentInteractions: [
                InteractionChip(title: "Email", subtitle: "Introduced new client lead", whenText: "1w", icon: "envelope")
            ],
            insights: []
        ),
        PersonDetailModel(
            id: UUID(),
            displayName: "Cynthia Lopez",
            roleBadges: ["Vendor", "Underwriting Liaison"],
            consentAlertsCount: 0,
            reviewAlertsCount: 1,
            contexts: [
                ContextChip(name: "Carrier: NorthBridge", kindDisplay: "Vendor", icon: "briefcase")
            ],
            responsibilityNotes: [],
            recentInteractions: [
                InteractionChip(title: "Call", subtitle: "Clarified underwriting requirements", whenText: "3d", icon: "phone")
            ],
            insights: [
                PersonMockInsight(kind: .complianceWarning,
                                  message: "Household survivorship structure requires review following relationship change.",
                                  confidence: 0.88,
                                  interactionsCount: 2,
                                  consentsCount: 1)
            ]
        )
    ]

    static let byID: [UUID: PersonDetailModel] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static let listItems: [PersonListItemModel] = all.map { p in
        PersonListItemModel(
            id: p.id,
            displayName: p.displayName,
            roleBadges: p.roleBadges,
            consentAlertsCount: p.consentAlertsCount,
            reviewAlertsCount: p.reviewAlertsCount
        )
    }
}
