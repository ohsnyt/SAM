//
//  RelationshipRole.swift
//  SAM_crm
//
//  Created by David Snyder on 2/1/26.
//

import Foundation

enum RelationshipRole: String, CaseIterable, Identifiable {
    case primary
    case spouse
    case dependent
    case recruitCandidate
    case agentExternal
    case referralPartner
    case vendor
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .primary: return "Primary"
        case .spouse: return "Spouse / Joint Signer"
        case .dependent: return "Dependent"
        case .recruitCandidate: return "Recruit Candidate"
        case .agentExternal: return "External Agent"
        case .referralPartner: return "Referral Partner"
        case .vendor: return "Vendor"
        case .other: return "Other"
        }
    }

    var roleBadges: [String] {
        switch self {
        case .primary: return ["Primary"]
        case .spouse: return ["Spouse"]
        case .dependent: return ["Dependent"]
        case .recruitCandidate: return ["Recruit"]
        case .agentExternal: return ["Agent External"]
        case .referralPartner: return ["Referral Partner"]
        case .vendor: return ["Vendor"]
        case .other: return ["Participant"]
        }
    }

    var icon: String {
        switch self {
        case .primary: return "person.fill"
        case .spouse: return "person.2.fill"
        case .dependent: return "figure.child"
        case .recruitCandidate: return "person.badge.plus"
        case .agentExternal: return "person.crop.circle.badge.checkmark"
        case .referralPartner: return "arrow.triangle.2.circlepath"
        case .vendor: return "briefcase"
        case .other: return "person"
        }
    }

    var makesPrimary: Bool { self == .primary }
}
