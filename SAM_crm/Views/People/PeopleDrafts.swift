//
//  PeopleDrafts.swift
//  SAM_crm
//
//  Created by David Snyder on 2/1/26.
//

import Foundation

struct NewPersonDraft {
    let fullName: String
    let rolePreset: PersonRolePreset
}

enum PersonRolePreset: String, CaseIterable, Identifiable {
    case individualClient
    case businessOwner
    case recruitCandidate
    case agentExternal
    case referralPartner
    case vendor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .individualClient: return "Individual / Family Client"
        case .businessOwner: return "Business Owner"
        case .recruitCandidate: return "Recruit Candidate"
        case .agentExternal: return "External Agent"
        case .referralPartner: return "Referral Partner"
        case .vendor: return "Vendor"
        }
    }

    var roleBadges: [String] {
        switch self {
        case .individualClient: return ["Client"]
        case .businessOwner: return ["Client", "Business Owner"]
        case .recruitCandidate: return ["Recruit Candidate"]
        case .agentExternal: return ["Agent External"]
        case .referralPartner: return ["Referral Partner"]
        case .vendor: return ["Vendor"]
        }
    }
}
