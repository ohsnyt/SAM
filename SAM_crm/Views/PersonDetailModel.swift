//
//  PersonDetailModel.swift
//  SAM_crm
//
//  Created by David Snyder on 2/1/26.
//

import SwiftUI

struct PersonDetailModel: Identifiable {
    let id: UUID
    let displayName: String
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

    // Insights
    let insights: [PersonMockInsight]
}

// MARK: - Supporting types

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

struct PersonMockInsight: InsightDisplayable {
    let kind: InsightKind
    let message: String
    let confidence: Double
    let interactionsCount: Int
    let consentsCount: Int
}
