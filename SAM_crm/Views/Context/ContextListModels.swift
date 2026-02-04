//
//  ContextListModels.swift
//  SAM_crm
//
//  Created by David Snyder on 1/31/26.
//

import SwiftUI

struct ContextListItemModel: Identifiable, Codable {
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

