//
//  ContextDetailModel.swift
//  SAM_crm
//
//  Created by David Snyder on 1/31/26.
//

import SwiftUI

// MARK: - Models used by ContextDetailView (mock-first)


struct ContextDetailModel: Identifiable {
    let id: UUID
    let name: String
    let kind: ContextKind
    let alerts: ContextAlerts

    let participants: [ContextParticipantModel]
    let products: [ContextProductModel]
    let consentRequirements: [ConsentRequirementModel]
    let recentInteractions: [InteractionModel]
    let insights: [ContextMockInsight]

    var kindDisplay: String { kind.displayName }
}

extension ContextDetailModel {
    var listSubtitle: String {
        let p = participants.count
        let prod = products.count
        return "\(kind.displayName) • \(p) participant\(p == 1 ? "" : "s") • \(prod) product\(prod == 1 ? "" : "s")"
    }
}

struct ContextAlerts {
    let consentCount: Int
    let reviewCount: Int
    let followUpCount: Int
}

struct ContextParticipantModel: Identifiable {
    let id: UUID
    let displayName: String
    let roleBadges: [String]
    let icon: String
    let isPrimary: Bool
    let note: String?
}

struct ContextProductModel: Identifiable {
    let id: UUID
    let title: String
    let subtitle: String?
    let statusDisplay: String
    let icon: String
}

struct ConsentRequirementModel: Identifiable {
    enum Status {
        case required, satisfied, revoked, expired
    }

    let id: UUID
    let title: String                 // e.g. "Mary Smith (Spouse) must consent"
    let reason: String                // e.g. "Joint spousal consent required"
    let jurisdiction: String?
    let status: Status

    var statusDisplay: String {
        switch status {
        case .required:  return "Required"
        case .satisfied: return "Satisfied"
        case .revoked:   return "Revoked"
        case .expired:   return "Expired"
        }
    }

    var statusIcon: String {
        switch status {
        case .required:  return "checkmark.seal"
        case .satisfied: return "checkmark.seal.fill"
        case .revoked:   return "xmark.seal"
        case .expired:   return "clock.badge.exclamationmark"
        }
    }

    var statusColor: Color {
        switch status {
        case .required:  return .secondary
        case .satisfied: return .secondary
        case .revoked:   return .secondary
        case .expired:   return .orange
        }
    }
}

struct InteractionModel: Identifiable {
    let id: UUID
    let title: String
    let subtitle: String
    let whenText: String
    let icon: String
}

// MARK: - Insight type compatible with InsightCardView

struct ContextMockInsight: InsightDisplayable {
    let kind: InsightKind
    let message: String
    let confidence: Double
    let interactionsCount: Int
    let consentsCount: Int
}

// MARK: - Sample context (divorce stress story context example)

enum MockContexts {
    static let smithHousehold: ContextDetailModel = ContextDetailModel(
        id: UUID(),
        name: "John & Mary Smith",
        kind: .household,
        alerts: ContextAlerts(consentCount: 2, reviewCount: 1, followUpCount: 1),
        participants: [
            ContextParticipantModel(
                id: UUID(),
                displayName: "John Smith",
                roleBadges: ["Client", "Primary Insured"],
                icon: "person.crop.circle",
                isPrimary: true,
                note: nil
            ),
            ContextParticipantModel(
                id: UUID(),
                displayName: "Mary Smith",
                roleBadges: ["Client", "Spouse", "Joint Signer", "Joint Beneficiary (Survivorship)"],
                icon: "person.crop.circle",
                isPrimary: false,
                note: "Recent signals suggest marital status may have changed — confirm."
            ),
            ContextParticipantModel(
                id: UUID(),
                displayName: "Emma Smith",
                roleBadges: ["Dependent", "Minor"],
                icon: "person.crop.circle",
                isPrimary: false,
                note: "Consent must be provided by responsible person/guardian."
            ),
            ContextParticipantModel(
                id: UUID(),
                displayName: "Evan Patel",
                roleBadges: ["Referral Partner", "Estate Planning Attorney"],
                icon: "person.crop.circle",
                isPrimary: false,
                note: "Bidirectional referral relationship."
            ),
            ContextParticipantModel(
                id: UUID(),
                displayName: "Cynthia Lopez",
                roleBadges: ["Vendor", "Underwriting Liaison"],
                icon: "person.crop.circle",
                isPrimary: false,
                note: nil
            )
        ],
        products: [
            ContextProductModel(
                id: UUID(),
                title: "Term Life Policy – John Smith",
                subtitle: "Coverage review due after household change.",
                statusDisplay: "Active",
                icon: "shield"
            ),
            ContextProductModel(
                id: UUID(),
                title: "Long-Term Care – Joint Consideration",
                subtitle: "Re-evaluate affordability and goals post-divorce.",
                statusDisplay: "Proposed",
                icon: "cross.case"
            ),
            ContextProductModel(
                id: UUID(),
                title: "College Savings – Emma Smith",
                subtitle: "Dependent context; guardian consent required for changes.",
                statusDisplay: "Active",
                icon: "graduationcap"
            )
        ],
        consentRequirements: [
            ConsentRequirementModel(
                id: UUID(),
                title: "Mary Smith (Spouse) must consent",
                reason: "Joint spousal consent required for survivorship beneficiary changes.",
                jurisdiction: "MO",
                status: .required
            ),
            ConsentRequirementModel(
                id: UUID(),
                title: "Guardian consent for Emma Smith",
                reason: "Dependent cannot provide consent; responsible person must approve changes.",
                jurisdiction: nil,
                status: .required
            )
        ],
        recentInteractions: [
            InteractionModel(id: UUID(), title: "Zoom call", subtitle: "Household review and next steps", whenText: "2d", icon: "video"),
            InteractionModel(id: UUID(), title: "Message", subtitle: "Scheduling follow-up questions", whenText: "5d", icon: "message"),
            InteractionModel(id: UUID(), title: "Email", subtitle: "Document request: beneficiary info", whenText: "1w", icon: "envelope")
        ],
        insights: [
            ContextMockInsight(kind: .relationshipAtRisk,
                               message: "Possible divorce trigger: interaction patterns changed and spouse consent context may need re-confirmation.",
                               confidence: 0.74,
                               interactionsCount: 4,
                               consentsCount: 1),
            ContextMockInsight(kind: .consentMissing,
                               message: "Joint survivorship structure requires updated spousal consent before beneficiary changes can proceed.",
                               confidence: 0.93,
                               interactionsCount: 1,
                               consentsCount: 2),
            ContextMockInsight(kind: .complianceWarning,
                               message: "Dependent consent boundary detected: guardian approval required for changes involving Emma Smith.",
                               confidence: 0.88,
                               interactionsCount: 0,
                               consentsCount: 1)
        ]
    )
}
