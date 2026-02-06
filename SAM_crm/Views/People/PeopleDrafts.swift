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

    /// The email address that prompted this person's creation (e.g. from an
    /// Inbox participant hint).  Nil when the person is created manually via
    /// the "New Person" sheet with no hint context.
    var email: String? = nil

    /// The stable `CNContact.identifier` resolved at creation time, when
    /// available.  Nil for manually-created people or when Contacts access
    /// hasn't been granted yet.  Can be filled in later via
    /// `PeopleRepository` once the contact is matched.
    var contactIdentifier: String? = nil
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
