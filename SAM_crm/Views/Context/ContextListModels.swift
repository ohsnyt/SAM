//
//  ContextListModels.swift
//  SAM_crm
//
//  Created by David Snyder on 1/31/26.
//

import SwiftUI

enum ContextKind: String, Codable, Hashable {
    case household
    case business
    case recruiting

    var displayName: String {
        switch self {
        case .household: return "Household"
        case .business: return "Business"
        case .recruiting: return "Recruiting"
        }
    }

    var icon: String {
        switch self {
        case .household: return "house"
        case .business: return "building.2"
        case .recruiting: return "person.3"
        }
    }
}

struct ContextListItemModel: Identifiable {
    let id: UUID
    let name: String
    let subtitle: String
    let kind: ContextKind

    let consentCount: Int
    let reviewCount: Int
    let followUpCount: Int

    var alertScore: Int { consentCount * 3 + reviewCount * 2 + followUpCount }
}

enum ContextKindFilter: String, CaseIterable, Identifiable {
    case all
    case household
    case business
    case recruiting

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .household: return "Households"
        case .business: return "Business"
        case .recruiting: return "Recruiting"
        }
    }
}

