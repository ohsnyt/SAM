//
//  PersonRowModel.swift
//  SAM_crm
//
//  Created by David Snyder on 1/31/26.
//

import SwiftUI

// MARK: - Row Model

struct PersonRowModel: Identifiable {
    let id: UUID
    let displayName: String

    // Role badges: include your new types here
    let roleBadges: [String]

    // Alerts
    let consentAlertsCount: Int
    let reviewAlertsCount: Int

    // Contexts
    let contexts: [ContextChip]

    // Obligations
    let responsibilityNotes: [String]

    // Interactions
    let recentInteractions: [InteractionChip]

    // Insights (re-using your InsightDisplayable abstraction)
    let insights: [PersonMockInsight]
}

// MARK: - Context / Interaction

struct ContextChip: Identifiable {
    let id = UUID()
    let name: String
    let kindDisplay: String
    let icon: String
}

struct InteractionChip: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let whenText: String
    let icon: String
}

// MARK: - Mock Insight compatible with InsightCardView

struct PersonMockInsight: InsightDisplayable {
    let kind: InsightKind
    let message: String
    let confidence: Double
    let interactionsCount: Int
    let consentsCount: Int
}

// MARK: - Sample data

enum MockPeopleData {
    static let allPeople: [PersonRowModel] = [
        PersonRowModel(
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
        PersonRowModel(
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
        PersonRowModel(
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
}
