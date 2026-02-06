//
//  ContextDetailModel.swift
//  SAM_crm
//
//  Created by David Snyder on 1/31/26.
//

import SwiftUI

struct ContextDetailModel: Identifiable, Codable {
    let id: UUID
    let name: String
    let kind: ContextKind
    let alerts: ContextAlerts

    let participants: [ContextParticipantModel]
    let products: [ContextProductModel]
    let consentRequirements: [ConsentRequirementModel]
    let recentInteractions: [InteractionModel]
    let insights: [ContextInsight]

    var kindDisplay: String { kind.displayName }
}

extension ContextDetailModel {
    var listSubtitle: String {
        let p = participants.count
        let prod = products.count
        return "\(kind.displayName) • \(p) participant\(p == 1 ? "" : "s") • \(prod) product\(prod == 1 ? "" : "s")"
    }
}

struct ContextAlerts: Codable {
    let consentCount: Int
    let reviewCount: Int
    let followUpCount: Int
}

struct ContextParticipantModel: Identifiable, Codable {
    let id: UUID
    let displayName: String
    let roleBadges: [String]
    let icon: String
    let isPrimary: Bool
    let note: String?
}

struct ConsentRequirementModel: Identifiable, Codable {
    /// Raw-value enum so the synthesised `Codable` conformance works.
    enum Status: String, Codable {
        case required, satisfied, revoked, expired
    }

    let id: UUID
    let title: String                 // e.g. "Mary Smith (Spouse) must consent"
    let reason: String                // e.g. "Joint spousal consent required"
    let jurisdiction: String?
    let status: Status

    // MARK: - Derived (not persisted)

    /// Only the five stored properties above are encoded/decoded.
    /// The computed display helpers below are excluded automatically
    /// because they have no backing storage.
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
